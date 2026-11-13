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
- `IMM_SPARKLE_PUBLIC_KEY`: the public half of your Sparkle EdDSA key. The default feed is `https://gasi.dev/imm/appcast.xml`.
- `IMM_CLOUDKIT_CONTAINER`: your iCloud container for the sync relay.

After editing `Local.xcconfig`, rebuild; regenerating the project is not needed.

The sync agent's app group and Mach service carry the team ID literally, because launchd and the sandbox read them before any build setting applies. With another team, replace `HHK7S6D2TR` in `Agent/IMMSyncAgent.entitlements`, `Agent/dev.gasi.imm.sync-agent.plist`, `App/IMM.entitlements`, `App/IMM-Unsigned.entitlements` and `Packages/IMMKit/Sources/IMMSyncCore/Agent/AgentConstants.swift`.

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

`.github/workflows/ci.yml` runs on every push and pull request, on GitHub's `xcode-27` macOS runner: it builds the `Debug-Unsigned` app (no signing secrets are needed or stored) and runs `swift test`. The design-diff images are uploaded as a workflow artifact. Dependabot keeps the actions and Swift packages current.

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

## Strings

All UI strings are English literals in code (`Text("…", bundle: .module)`). The compiler extracts them during a build, but only the Xcode IDE writes them into `Packages/IMMKit/Sources/IMMUI/Resources/Localizable.xcstrings`. After a command-line build, fill the catalog with:

```sh
Tools/sync-strings.sh   # reads the .stringsdata files under build/dd
```

Never edit the catalog's source strings by hand.

## Release

`Tools/release.sh` builds the `Release` configuration, signs it with Developer ID, notarizes, packages and writes the Sparkle feed:

```sh
Tools/release.sh                  # full release
Tools/release.sh --skip-notarize  # build, sign, zip and appcast only
```

Steps: `xcodegen generate`, `xcodebuild archive`, `xcodebuild -exportArchive` with `Config/ExportOptions.plist` (method `developer-id`, team `HHK7S6D2TR`), `ditto` zip, `notarytool submit --wait` and `stapler staple`, then Sparkle `generate_appcast` with download prefix `https://gasi.dev/imm/`.

Prerequisites:

- A Developer ID Application certificate for the team in your Keychain.
- A notarytool profile named `imm-notary`. If it is missing the script prints the command and exits non-zero:
  ```sh
  xcrun notarytool store-credentials imm-notary
  ```
- Sparkle's EdDSA private key in the login Keychain (created once with Sparkle's `generate_keys`, found with `find build -name generate_keys`; it prints the public key for `IMM_SPARKLE_PUBLIC_KEY`).

Output is in `build/release/`: `IMM-<version>.zip` and `appcast.xml`. Upload both to `https://gasi.dev/imm/`. The script uploads nothing.

Check the result:

```sh
codesign --verify --strict --verbose=2 build/release/IMM.app
codesign -d --entitlements - build/release/IMM.app
```

The entitlements must list `keychain-access-groups`.
