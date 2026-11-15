# Building IMM

## Requirements

- macOS 26 or later
- Xcode 27.2 (Swift 6.4)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

Use the full Xcode toolchain for every `xcodebuild`, `xcrun` and `swift` call. Without it, `xcodebuild` may resolve a missing Command Line Tools SDK:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

All commands below run in the repository root and assume this variable is set.

## Generate the project

`IMM.xcodeproj` is generated from `project.yml` and is git-ignored:

```sh
xcodegen generate
```

Run it again after changing `project.yml`, `Config/` or adding files under `App/`.

## Configurations

| Configuration | Config file | Signing | Entitlements |
| --- | --- | --- | --- |
| `Debug` | `Config/Signed.xcconfig` | Automatic, team `HHK7S6D2TR`, Apple Development | `App/IMM.entitlements` |
| `Release` | `Config/Signed.xcconfig` | Automatic, team `HHK7S6D2TR` | `App/IMM.entitlements` |
| `Debug-Unsigned` | `Config/Unsigned.xcconfig` | Ad-hoc (`-`), no team, no provisioning profile | `App/IMM-Unsigned.entitlements` |

All configurations are sandboxed with hardened runtime.

Signed build (needs Xcode signed in to a developer account that can provision the bundle id):

```sh
xcodebuild -project IMM.xcodeproj -scheme IMM -configuration Debug \
  -destination 'platform=macOS' \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -derivedDataPath build/dd build
```

Unsigned build, no account needed:

```sh
xcodebuild -project IMM.xcodeproj -scheme IMM -configuration Debug-Unsigned \
  -destination 'platform=macOS' -derivedDataPath build/dd build
```

The app ends up in `build/dd/Build/Products/<configuration>/IMM.app`.

### What the unsigned build lacks

`IMM-Unsigned.entitlements` has no `keychain-access-groups`, because that entitlement needs a provisioning profile. Consequences:

- Touch ID cannot store the database key. The Create vault and Settings switches are disabled with "Touch ID needs a signed build of IMM.".
- Banking PINs go to the file-based keychain instead of the data-protection keychain.

Password create, unlock, auto-lock and everything else work.

## Forks: `Config/Local.xcconfig`

`Config/Base.xcconfig` ends with `#include? "Local.xcconfig"`, and both `Signed.xcconfig` and `Unsigned.xcconfig` include `Base.xcconfig` last. A git-ignored `Config/Local.xcconfig` therefore overrides any setting. Example:

```xcconfig
DEVELOPMENT_TEAM = ABCDE12345
PRODUCT_BUNDLE_IDENTIFIER = com.example.imm
IMM_FEED_URL = https:/$()/example.com/imm/appcast.xml
IMM_SPARKLE_PUBLIC_KEY = <base64 EdDSA public key printed by generate_keys>
IMM_CLOUDKIT_CONTAINER = iCloud.com.example.imm
```

- `DEVELOPMENT_TEAM`: your Apple team.
- `PRODUCT_BUNDLE_IDENTIFIER`: the keychain access group, the Sparkle mach-lookup names and the document UTI follow it.
- `IMM_FEED_URL`: Sparkle appcast URL. Write `https:/$()/…`: a plain `//` starts a comment in xcconfig files.
- `IMM_SPARKLE_PUBLIC_KEY`: the public half of your Sparkle EdDSA key. The default feed is `https://github.com/RobinGasi/IMM/releases/latest/download/appcast.xml`.
- `IMM_CLOUDKIT_CONTAINER`: your iCloud container for the sync relay.

After editing `Local.xcconfig`, rebuild; regenerating the project is not needed.

The sync agent's app group and Mach service carry the team ID literally, because launchd and the sandbox read them before any build setting applies. With another team, replace `HHK7S6D2TR` in `Agent/IMMSyncAgent.entitlements`, `Agent/dev.gasi.imm.sync-agent.plist`, `App/IMM.entitlements`, `App/IMM-Unsigned.entitlements` and `Packages/IMMKit/Sources/IMMSyncCore/Agent/AgentConstants.swift`.

## FinTS bank access

The FinTS connector (`Packages/IMMKit/Sources/IMMFinTS/`) is read-only: SEPA accounts (`HKSPA`), balances (`HKSAL`) and statements (`HKCAZ` camt.052/053, else `HKKAZ` MT940/MT942), with strong customer authentication by decoupled TAN methods (approval in the bank's app). It needs two things the Deutsche Kreditwirtschaft hands out only after a free product registration at [fints.org › Produktregistrierung](https://www.fints.org/de/hersteller/produktregistrierung):

1. **The registration number.** Set it in `Config/Local.xcconfig` (or `Config/Base.xcconfig` for official builds):
   ```xcconfig
   IMM_FINTS_PRODUCT_ID = <registration number>
   ```
   It reaches the app as the `Info.plist` key `IMMFinTSProductID` and is sent in every dialog (`HKVVB`). Library registration numbers must not be used in a shipped app.
2. **The FinTS bank list** (`fints_institute.csv`). Convert it into the bundled directory:
   ```sh
   swift Tools/import-fints-banks.swift fints_institute.csv > Packages/IMMKit/Sources/IMMFinTS/Resources/FinTSBanks.json
   ```
   Check the list's terms before committing the generated file.

`AppModel.makeDefaultConnector()` picks the FinTS connector when both are present and the demo connector otherwise; the Debug demo vault always uses the demo connector. The connector keeps the FinTS system id and the chosen TAN method per login in `UserDefaults` (never the PIN). Payment controls show "Soon" because the connector reports `supportsPayments == false`.

## Debug demo vault and Debug menu

Debug builds accept a launch argument that creates a demo database, imports the demo ledger, unlocks it and opens the main window:

```sh
open -n build/dd/Build/Products/Debug/IMM.app --args -IMMDemoVault YES
```

The vault is `IMM-Demo.imm` in the app's temporary directory (inside the sandbox container); the password is `demo-demo`. The argument does nothing in `Release`.

To test onboarding from scratch, start a Debug build with `-IMMResetState YES`. It forgets the remembered database, the lock-screen info and the Touch ID setting, removes the Keychain vault keys and banking PINs of every database the app remembers, and deletes the demo vault; database packages you saved yourself stay on disk:

```sh
open -n build/dd/Build/Products/Debug/IMM.app --args -IMMResetState YES
```

Debug builds also have a Debug menu:

- **Demo bank sync** ▸ Succeeds / Fails: with Fails, Sync produces the Sync failed layout (rejected PIN for Sparkasse KölnBonn, maintenance for DKB).
- **Demo bank approval** ▸ Approves / Expires: with Expires, a transfer or sign-in ends in the TAN expired sheet.

## Tests

```sh
swift test --package-path Packages/IMMKit
```

If SwiftPM cannot load the binary frameworks, run the same tests through Xcode:

```sh
cd Packages/IMMKit
xcodebuild test -scheme IMMKit-Package -destination 'platform=macOS'
```

Screen comparison tests render each screen offscreen and compare it with `DesignReference/screens/<slug>@1x.png`. Results (mismatch share per screen, diff images) are written to `build/design-diff/report.json` and `build/design-diff/<slug>.png`. Allowed mismatch values are in `DesignReference/thresholds.json`. Text rendering differs slightly between macOS versions; the references were made on macOS 27.

### README image

`.github/images/imm.png` is rendered from the real views and the demo ledger by a test that is skipped unless asked for:

```sh
IMM_README_SCREENSHOT=1 swift test --package-path Packages/IMMKit --filter ReadmeScreenshotTests
```

## Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request, on GitHub's `xcode-27` macOS runner: it builds the `Debug-Unsigned` app (no signing secrets are needed or stored), builds the iPhone app `IMMPhone` for `generic/platform=iOS` with `CODE_SIGNING_ALLOWED=NO`, and runs `swift test`. The design-diff images are uploaded as a workflow artifact. Dependabot keeps the actions and Swift packages current.

### Demo figures

`imm-demo-report` builds a temporary vault, imports the demo ledger and prints every figure the screens show as one JSON object keyed `<screen>.<figure>`:

```sh
swift run --package-path Packages/IMMKit imm-demo-report | jq '."overview.netWorth", ."overview.spentSoFar", ."sidebar.newCount"'
```

## Design reference

`DesignReference/` holds what the build and the tests read from the design:

- `screens/<slug>@1x.png` and `screens/index.tsv`: a 1x screenshot of every designed screen and state, the references for the comparison tests.
- `flows.json`: the prototype's links (source screen, clicked element, target screen), walked by `FlowTests`.
- `imm.json`: the design system (colour tokens light and dark, radii, component sources).
- `icons/`: the app and document icon masters.
- `thresholds.json`: allowed mismatch per screen comparison.

### Design tokens

Colours and radii in `Packages/IMMKit/Sources/IMMDesign/Generated/Tokens.swift` are generated from `DesignReference/imm.json`. Never edit that file by hand; after changing the design system run:

```sh
swift Tools/generate-tokens.swift
```

## Sync over Tailscale

The full design rationale is in the source comments of the modules below.

- **Pieces.** `IMMSyncCore` (Noise, pairing code, sealed envelopes, messages, mailbox, the agent server) and `IMMSync` (device identity, pairing, batches, `SyncService`, `SyncClient`). The app embeds `IMM Sync Agent.app` in `Contents/Library/LoginItems/` with the LaunchAgent plist `Contents/Library/LaunchAgents/dev.gasi.imm.sync-agent.plist`; turning on "Sync over Tailscale" registers it with `SMAppService`, turning it off unregisters it. The agent listens only on the Mac's Tailscale address, port 47380, and never holds a key that opens a batch.
- **Entitlements.** The agent has the app group `HHK7S6D2TR.dev.gasi.imm` and `network.server` and no provisioning profile. The app has no app group (its profile can't carry one); it reaches the agent through the Mach service `HHK7S6D2TR.dev.gasi.imm.sync-agent` (lookup exception). In `Debug-Unsigned` the agent can't write its container, so sync stays off there.
- **Debug launch arguments** (Debug builds only): `-IMMSyncEnable YES`, `-IMMSyncDisable YES`, `-IMMSyncPrintPairingCode YES` (prints the pairing code and agent key to stdout), `-IMMSyncAutoConfirm YES` (tests only), `-IMMSyncDebugEdit YES` (reads JSON edit lines from stdin), `-IMMSyncDumpOnChange YES`, `-IMMDemoVaultFresh YES`.
- **Test peer.** `swift run --package-path Packages/IMMKit imm-sync-peer --help`: a headless second device with its own vault (`init`, `pair`, `sync [--watch]`, `set-category`, `set-note`, `dump`, `devices`).
- **Two-device test over a real tailnet path:** `Tools/sync-tailnet-test.sh --ssh-host HOST [--rounds N]`. Needs Tailscale running and an ssh host on your tailnet that can reach this Mac; it forwards a local port through that host to the Mac's tailnet address, pairs the peer, measures latency both ways, checks the mailbox path and that nothing listens on the LAN, then turns sync off and cleans up.

### iCloud relay (async lane)

The relay lets a device sync while the other is asleep, locked or offline: every sealed batch also goes to the user's private CloudKit database, and a device that wakes up or unlocks fetches what it missed. It carries only the batches the live lane carries (sealed under the group key, so CloudKit sees ciphertext, the group id, node ids and sequence numbers). Pairing, the group key and rekeys stay on the live lane. Code: `Packages/IMMKit/Sources/IMMSync/Relay/`.

- **Shape.** Container `iCloud.dev.gasi.imm` (`IMM_CLOUDKIT_CONTAINER`), private database, custom zone `imm-sync`, record type `SealedBatch` with fields `blob` (bytes, up to 256 KiB) or `asset` (`CKAsset` above that), `group`, `device`, `seqFrom`, `seqTo`, random record names, never updated. A small relay ack (a sealed envelope with sequence numbers at or above `RelayLane.ackBase`, same record type) lets a device delete a batch once every other paired device acknowledged it; anything older than 90 days is deleted regardless. The `CKSyncEngine` state, the upload queue and undelivered items live in the vault (`sync_secret`), not in files.
- **When it runs.** Only while sync is on and a vault is unlocked, in a signed build whose entitlements carry iCloud (`CloudKitAvailability.check()`: `com.apple.developer.icloud-services` first, then `accountStatus`). `Debug-Unsigned` and the SwiftPM test runners never create a `CKContainer`. Status is `SyncService.relayStatus` (`unavailable(reason)`, `ready`, `syncing`, `error`); a device whose last batch came through the relay shows "via iCloud" in the device list. The app registers for remote notifications once (needs `aps-environment`); `CKSyncEngine` handles the silent pushes itself, and the relay also fetches on launch, unlock, wake and "Sync now".
- **Tests.** `swift test --filter Relay`: replicas that exchange only through `InMemoryRelayStore` (no CloudKit).
- **Self-test against the real service** (Debug builds, signed): `build/dd/Build/Products/Debug/IMM.app/Contents/MacOS/IMM -IMMCloudKitSelfTest YES -ApplePersistenceIgnoreState YES`. It creates two temporary vaults, pairs them offline, exchanges edits through zone `imm-sync-selftest` in the Development environment with explicit `sendChanges` / `fetchChanges`, prints `CLOUDKIT SELFTEST PASS` or `FAIL`, deletes the zone and the vaults, and exits. It measures round trips through the server, not push latency (CloudKit never pushes to the device that made a change).
- **Production deploy (maintainer steps, once per container).** (1) The App ID has iCloud (CloudKit, your container) and Push Notifications. (2) The record type `SealedBatch` exists in Development once the self-test or any signed Debug run saved a record; open CloudKit Console › Schema › `SealedBatch` and check the six fields (`blob` bytes, `asset` asset, `group` bytes, `device` int64, `seqFrom` int64, `seqTo` int64). (3) Press "Deploy Schema Changes" to copy the schema to Production (records are not copied; Production is forward-only, so do this only when the fields are final). (4) Release builds use `IMM_CLOUDKIT_ENVIRONMENT = Production` and `IMM_APS_ENVIRONMENT = production`; `Tools/release.sh` refuses an export without them. (5) On the first Production run with two devices, check that pushes arrive (the engine falls back to fetching on launch, unlock and wake).

## iPhone companion

`IMMPhone` is the iPhone app (iOS 26, iPhone only, portrait). It pairs with IMM on the Mac and keeps an encrypted copy of the ledger. Code: `Packages/IMMKit/Sources/IMMCompanion/` (model and screens, also built and tested on macOS) and `Phone/` (the `@main` app, the QR scanner, `Info.plist`, `IMMPhone.entitlements`, `Assets.xcassets`). Build settings: `Config/Phone.xcconfig`; bundle id `dev.gasi.imm` (the same App ID as the Mac app), team `HHK7S6D2TR`.

### Building

```sh
xcodegen generate
xcodebuild -project IMM.xcodeproj -scheme IMMPhone -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build/dd-phone \
  CODE_SIGNING_ALLOWED=NO build
```

This is what CI runs. It needs no account but produces an app that cannot be installed.

### Running on a device

Open `IMM.xcodeproj`, pick the `IMMPhone` scheme and your iPhone, and run. Debug uses automatic signing with the team (Xcode signed in to an account that can provision `dev.gasi.imm`; the iPhone needs Developer Mode and must be registered). Or on the command line:

```sh
xcodebuild -project IMM.xcodeproj -scheme IMMPhone -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build/dd-phone \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

The app needs the camera (pairing QR code), Face ID and the local network (to reach the Mac). Pairing and sync run over Tailscale like the Mac-to-Mac sync (see "Sync over Tailscale"): Tailscale must be running on the iPhone. The keychain access group is `$(AppIdentifierPrefix)dev.gasi.imm`.

### TestFlight

The `testflight` job of the `Release` workflow runs `Tools/release-ios.sh --upload` next to the macOS release job; neither waits for the other. It uses the same version (`IMM_VERSION`) and build number (commit count of `HEAD`) rules as `Tools/release.sh`, signs manually with Apple Distribution and uploads to App Store Connect with `xcodebuild -exportArchive` (export method `app-store-connect`, destination `upload`).

One-time setup: create the app record for `dev.gasi.imm` in App Store Connect by hand (the API cannot create apps), add testers to TestFlight, and add the secrets below. Builds appear in TestFlight after Apple's processing.

| Secret | Content |
| --- | --- |
| `IOS_DIST_P12`, `IOS_DIST_PASSWORD` | Apple Distribution certificate and key, base64 .p12 (build it with `/usr/bin/openssl`, like the Mac certificate) |
| `IOS_PROVISION_PROFILE` | base64 of the manually managed App Store profile `IMM iOS App Store (CI)` for `dev.gasi.imm`. It expires with the certificate |
| `MACOS_NOTARY_KEY`, `MACOS_NOTARY_KEY_ID`, `MACOS_NOTARY_ISSUER_ID` | The App Store Connect API key the Mac release already uses; it uploads the build |

`Tools/release-ios.sh` also runs locally:

```sh
Tools/release-ios.sh            # archive and export build/release-ios/IMM.ipa (automatic signing)
Tools/release-ios.sh --upload   # archive and upload to TestFlight; needs ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID
```

Environment variables (documented at the top of the script): `IMM_VERSION`, `IMM_BUILD`, `IMM_PHONE_PROFILE` (manual signing with that profile UUID instead of automatic signing), `ASC_KEY_PATH`/`ASC_KEY_ID`/`ASC_ISSUER_ID`. Output is under `build/release-ios/`.

## Strings

All UI strings are English literals in code (`Text("…", bundle: .module)`). The compiler extracts them during a build, but only the Xcode IDE writes them into `Packages/IMMKit/Sources/IMMUI/Resources/Localizable.xcstrings`. After a command-line build, fill the catalog with:

```sh
Tools/sync-strings.sh   # reads the .stringsdata files under build/dd
```

Never edit the catalog's source strings by hand.

## Release

Releases are cut by the `Release` workflow (`.github/workflows/release.yml`): Actions › Release › Run workflow with a version such as `0.2.0`, or push a tag `v0.2.0`. It runs CI first, then `Tools/release.sh` on the `xcode-27` runner, then creates the GitHub release `v<version>` (tag at the built commit, generated notes) with `IMM-<version>.dmg` (first install), `IMM-<version>.zip` (Sparkle update) and `appcast.xml` attached. The app's Sparkle feed is the `appcast.xml` of the newest release.

Repository secrets the workflow needs:

| Secret | Content |
| --- | --- |
| `MACOS_SIGN_P12`, `MACOS_SIGN_PASSWORD` | Developer ID Application certificate and key, base64 .p12 (build it with `/usr/bin/openssl`: `security import` rejects OpenSSL 3's default encryption) |
| `MACOS_PROVISION_PROFILE` | base64 of the manually managed Developer ID profile `IMM Developer ID (CI)` for `dev.gasi.imm`. It expires with the certificate; Xcode-managed profiles are refused under manual signing |
| `MACOS_NOTARY_KEY`, `MACOS_NOTARY_KEY_ID`, `MACOS_NOTARY_ISSUER_ID` | App Store Connect API key (.p8 contents) for `notarytool` |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key, exported with `generate_keys -x <file>` |

`Tools/release.sh` also runs locally:

```sh
Tools/release.sh                  # full release
Tools/release.sh --skip-notarize  # build, sign, zip and appcast only
```

Steps: `xcodegen generate`, `xcodebuild archive`, `xcodebuild -exportArchive` (method `developer-id`, team `HHK7S6D2TR`), `hdiutil` disk image (app plus an Applications link) signed with Developer ID, one `notarytool submit --wait` of the DMG, `stapler staple` on DMG and app, `ditto` zip of the stapled app, then Sparkle `generate_appcast` with download prefix `https://github.com/RobinGasi/IMM/releases/download/v<version>/`. `CFBundleVersion`, which Sparkle compares, is the commit count of `HEAD`.

Locally the script uses automatic signing (`Config/ExportOptions.plist`), the notarytool keychain profile `imm-notary` (missing: it prints the `store-credentials` command and exits non-zero) and Sparkle's private key from the login Keychain. The workflow switches each of these through environment variables documented at the top of the script: `IMM_APP_PROFILE` (manual signing with that profile), `NOTARY_KEY_PATH`/`NOTARY_KEY_ID`/`NOTARY_ISSUER_ID`, `SPARKLE_KEY_FILE`, plus `IMM_VERSION` and `IMM_BUILD`.

Output is in `build/release/`: `IMM-<version>.dmg`, `IMM-<version>.zip` and `appcast.xml`. The script uploads nothing.

Check the result:

```sh
codesign --verify --strict --verbose=2 build/release/IMM.app
codesign -d --entitlements - build/release/IMM.app
```

The entitlements must list `keychain-access-groups`.
