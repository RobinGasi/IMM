#!/usr/bin/env bash
# Builds, Developer ID signs, notarizes and packages IMM, then writes the Sparkle feed file.
#
#   Tools/release.sh [--skip-notarize]
#
# Output in build/release/: IMM.app, IMM-<version>.dmg (first install), IMM-<version>.zip (Sparkle
# updates), appcast.xml. Nothing is uploaded: the Release workflow (.github/workflows/release.yml)
# attaches them to the GitHub release v<version>, which the appcast's download URLs point at.
#
# Optional environment (the Release workflow sets all of them):
#   IMM_VERSION       marketing version (default: MARKETING_VERSION from Config/Base.xcconfig)
#   IMM_BUILD         CFBundleVersion, which Sparkle compares (default: commit count of HEAD)
#   IMM_APP_PROFILE   Developer ID provisioning profile UUID: sign manually with "Developer ID
#                     Application" instead of Xcode's automatic signing (no Xcode account needed)
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID
#                     App Store Connect API key for notarytool instead of the keychain profile
#   SPARKLE_KEY_FILE  Sparkle EdDSA private key file instead of the login Keychain
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

NOTARY_PROFILE="imm-notary"
TEAM_ID="HHK7S6D2TR"
RELEASES_URL="https://github.com/RobinGasi/IMM/releases/download"

SKIP_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="$ROOT/build/release"
ARCHIVE="$OUT/IMM.xcarchive"
APP="$OUT/IMM.app"
DERIVED="$ROOT/build/dd"

if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required with NOTARY_KEY_PATH}" \
    --issuer "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required with NOTARY_KEY_PATH}")
else
  NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
fi

# Notary credentials are checked first so a missing profile fails before the long build.
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  if ! xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1; then
    if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
      echo "notarytool rejected the API key in NOTARY_KEY_PATH (run 'xcrun notarytool history --key …' to see why)." >&2
    else
      cat >&2 <<EOF
The notarytool keychain profile "$NOTARY_PROFILE" does not exist (or cannot be used).
Create it once with an app-specific password from https://account.apple.com:

  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your Apple ID> --team-id $TEAM_ID

Then run this script again, or use --skip-notarize for a signed but not notarized build.
EOF
    fi
    exit 1
  fi
fi

echo "==> Generating project"
xcodegen generate

VERSION="${IMM_VERSION:-$(awk -F' *= *' '/^MARKETING_VERSION/{print $2; exit}' Config/Base.xcconfig)}"
# Sparkle orders updates by CFBundleVersion; the commit count only grows on main.
BUILD="${IMM_BUILD:-$(git rev-list --count HEAD)}"
ZIP="$OUT/IMM-$VERSION.zip"
DMG="$OUT/IMM-$VERSION.dmg"
echo "==> Version $VERSION ($BUILD)"

BUILD_SETTINGS=(MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD")
ARCHIVE_FLAGS=()
EXPORT_FLAGS=()
EXPORT_OPTIONS="$ROOT/Config/ExportOptions.plist"
if [[ -n "${IMM_APP_PROFILE:-}" ]]; then
  echo "==> Signing manually with Developer ID and profile $IMM_APP_PROFILE"
  BUILD_SETTINGS+=(IMM_SIGN_STYLE=Manual "IMM_SIGN_IDENTITY=Developer ID Application" IMM_APP_PROFILE="$IMM_APP_PROFILE")
  BUNDLE_ID="$(xcodebuild -project IMM.xcodeproj -scheme IMM -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = /{print $2; exit}')"
  # Outside $OUT: the export writes its own ExportOptions.plist there.
  EXPORT_OPTIONS="$ROOT/build/ExportOptions-manual.plist"
  mkdir -p "$ROOT/build"
  cat >"$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>$BUNDLE_ID</key>
		<string>$IMM_APP_PROFILE</string>
	</dict>
</dict>
</plist>
EOF
else
  ARCHIVE_FLAGS=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
  EXPORT_FLAGS=(-allowProvisioningUpdates)
fi

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Archiving (Release)"
xcodebuild archive \
  -project IMM.xcodeproj \
  -scheme IMM \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED" \
  ${ARCHIVE_FLAGS[@]+"${ARCHIVE_FLAGS[@]}"} \
  "${BUILD_SETTINGS[@]}"

echo "==> Exporting (Developer ID)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$OUT" \
  ${EXPORT_FLAGS[@]+"${EXPORT_FLAGS[@]}"}

[[ -d "$APP" ]] || { echo "Export did not produce $APP" >&2; exit 1; }

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Checking entitlements (Keychain, iCloud relay, push: Production)"
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - - )"
for check in \
  '."keychain-access-groups" | length > 0' \
  '."com.apple.developer.icloud-services" | index("CloudKit") != null' \
  '."com.apple.developer.icloud-container-identifiers" | length > 0' \
  '."com.apple.developer.icloud-container-environment" == "Production"' \
  '."com.apple.developer.aps-environment" == "production"'
do
  echo "$ENTITLEMENTS" | jq -e "$check" >/dev/null || { echo "Missing or wrong entitlement: $check" >&2; exit 1; }
done

echo "==> Building disk image"
# The DMG carries its own Developer ID signature; one notarization submission of it also
# registers the app inside, so both get stapled afterwards.
IDENTITY="$(security find-identity -v -p codesigning | awk -v team="($TEAM_ID)" '/"Developer ID Application: / && index($0, team) {print $2; exit}')"
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application identity for team $TEAM_ID in the keychain" >&2; exit 1; }
DMG_STAGE="$OUT/dmg-stage"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/IMM.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "IMM $VERSION" -srcfolder "$DMG_STAGE" -fs APFS -format ULFO -ov "$DMG" >/dev/null
rm -rf "$DMG_STAGE"
codesign --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  echo "==> Notarizing (this waits for Apple)"
  xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
else
  echo "==> Skipping notarization (--skip-notarize): signed, but Gatekeeper will reject the DMG and zip"
fi

echo "==> Packaging update zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Writing appcast"
GENERATE_APPCAST="$(find "$DERIVED/SourcePackages/artifacts" -name generate_appcast -type f -perm -u+x 2>/dev/null | head -n 1)"
[[ -n "$GENERATE_APPCAST" ]] || { echo "generate_appcast not found under $DERIVED/SourcePackages" >&2; exit 1; }
APPCAST_FLAGS=(--download-url-prefix "$RELEASES_URL/v$VERSION/")
[[ -n "${SPARKLE_KEY_FILE:-}" ]] && APPCAST_FLAGS+=(--ed-key-file "$SPARKLE_KEY_FILE")
# generate_appcast scans a directory of archives; keep only the new zip in it. Without
# SPARKLE_KEY_FILE the EdDSA private key is read from the login Keychain.
STAGE="$OUT/appcast-stage"
mkdir -p "$STAGE"
cp "$ZIP" "$STAGE/"
"$GENERATE_APPCAST" "${APPCAST_FLAGS[@]}" "$STAGE"
mv "$STAGE/appcast.xml" "$OUT/appcast.xml"
rm -rf "$STAGE"

echo
echo "Done. Attach these files to the GitHub release v$VERSION:"
echo "  $DMG"
echo "  $ZIP"
echo "  $OUT/appcast.xml"
