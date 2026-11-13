#!/usr/bin/env bash
# Builds, Developer ID signs, notarizes and packages IMM, then writes the Sparkle feed file.
#
#   Tools/release.sh [--skip-notarize]
#
# Output in build/release/: IMM.app, IMM-<version>.zip, appcast.xml. Upload the zip and appcast.xml
# to https://gasi.dev/imm/. Nothing is uploaded by this script.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

NOTARY_PROFILE="imm-notary"
TEAM_ID="HHK7S6D2TR"
DOWNLOAD_PREFIX="https://gasi.dev/imm/"

SKIP_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="$ROOT/build/release"
ARCHIVE="$OUT/IMM.xcarchive"
APP="$OUT/IMM.app"
DERIVED="$ROOT/build/dd"

# The notary profile is checked first so a missing profile fails before the long build.
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat >&2 <<EOF
The notarytool keychain profile "$NOTARY_PROFILE" does not exist (or cannot be used).
Create it once with an app-specific password from https://account.apple.com:

  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your Apple ID> --team-id $TEAM_ID

Then run this script again, or use --skip-notarize for a signed but not notarized build.
EOF
    exit 1
  fi
fi

echo "==> Generating project"
xcodegen generate

VERSION="$(xcodebuild -project IMM.xcodeproj -scheme IMM -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/^[[:space:]]*MARKETING_VERSION = /{print $2; exit}')"
if [[ -z "$VERSION" ]]; then
  VERSION="$(awk -F' *= *' '/^MARKETING_VERSION/{print $2; exit}' Config/Base.xcconfig)"
fi
ZIP="$OUT/IMM-$VERSION.zip"
echo "==> Version $VERSION"

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
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration

echo "==> Exporting (Developer ID)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist Config/ExportOptions.plist \
  -exportPath "$OUT" \
  -allowProvisioningUpdates

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

echo "==> Packaging"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  echo "==> Notarizing (this waits for Apple)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
else
  echo "==> Skipping notarization (--skip-notarize): the zip is signed but Gatekeeper will reject it"
fi

echo "==> Writing appcast"
GENERATE_APPCAST="$(find "$DERIVED/SourcePackages/artifacts" -name generate_appcast -type f -perm -u+x 2>/dev/null | head -n 1)"
[[ -n "$GENERATE_APPCAST" ]] || { echo "generate_appcast not found under $DERIVED/SourcePackages" >&2; exit 1; }
# generate_appcast scans a directory of archives; keep only the new zip in it. The EdDSA private key
# is read from the login Keychain.
STAGE="$OUT/appcast-stage"
mkdir -p "$STAGE"
cp "$ZIP" "$STAGE/"
"$GENERATE_APPCAST" --download-url-prefix "$DOWNLOAD_PREFIX" "$STAGE"
mv "$STAGE/appcast.xml" "$OUT/appcast.xml"
rm -rf "$STAGE"

echo
echo "Done. Upload these two files to $DOWNLOAD_PREFIX:"
echo "  $ZIP"
echo "  $OUT/appcast.xml"
