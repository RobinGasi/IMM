#!/usr/bin/env bash
# Builds and signs the IMM iPhone app for the App Store and exports it (or uploads it to TestFlight).
#
#   Tools/release-ios.sh [--upload]
#
# Without --upload the signed IMM.ipa is written to build/release-ios/. With --upload the export step
# sends the build to App Store Connect (TestFlight) instead. The app record for dev.gasi.imm must
# exist in App Store Connect first; the API cannot create it.
#
# Optional environment (the Release workflow sets all of them):
#   IMM_VERSION       marketing version (default: MARKETING_VERSION from Config/Base.xcconfig)
#   IMM_BUILD         CFBundleVersion, App Store Connect needs it to grow per version (default: commit
#                     count of HEAD, the same rule as Tools/release.sh)
#   IMM_PHONE_PROFILE App Store provisioning profile UUID: sign manually with "Apple Distribution"
#                     instead of Xcode's automatic signing (no Xcode account needed)
#   ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID
#                     App Store Connect API key (.p8) for xcodebuild: uploads the build and, without
#                     IMM_PHONE_PROFILE, lets Xcode manage signing
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

TEAM_ID="HHK7S6D2TR"

UPLOAD=0
for arg in "$@"; do
  case "$arg" in
    --upload) UPLOAD=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="$ROOT/build/release-ios"
ARCHIVE="$OUT/IMM.xcarchive"
DERIVED="$ROOT/build/dd-ios"

AUTH_FLAGS=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  AUTH_FLAGS=(-authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "${ASC_KEY_ID:?ASC_KEY_ID is required with ASC_KEY_PATH}" \
    -authenticationKeyIssuerID "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required with ASC_KEY_PATH}")
elif [[ $UPLOAD -eq 1 ]]; then
  echo "--upload needs an App Store Connect API key: set ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID." >&2
  exit 1
fi

echo "==> Generating project"
xcodegen generate

VERSION="${IMM_VERSION:-$(awk -F' *= *' '/^MARKETING_VERSION/{print $2; exit}' Config/Base.xcconfig)}"
BUILD="${IMM_BUILD:-$(git rev-list --count HEAD)}"
echo "==> Version $VERSION ($BUILD)"

BUILD_SETTINGS=(MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD")
ARCHIVE_FLAGS=()
EXPORT_FLAGS=()
# Outside $OUT: the export writes its own ExportOptions.plist there.
EXPORT_OPTIONS="$ROOT/build/ExportOptions-ios.plist"
mkdir -p "$ROOT/build"

if [[ $UPLOAD -eq 1 ]]; then DESTINATION="upload"; else DESTINATION="export"; fi

SIGNING_OPTIONS="	<key>signingStyle</key>
	<string>automatic</string>"
if [[ -n "${IMM_PHONE_PROFILE:-}" ]]; then
  echo "==> Signing manually with Apple Distribution and profile $IMM_PHONE_PROFILE"
  BUILD_SETTINGS+=(IMM_PHONE_SIGN_STYLE=Manual "IMM_PHONE_SIGN_IDENTITY=Apple Distribution" IMM_PHONE_PROFILE="$IMM_PHONE_PROFILE")
  BUNDLE_ID="$(xcodebuild -project IMM.xcodeproj -target IMMPhone -configuration Release -sdk iphoneos -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = /{print $2; exit}')"
  [[ -n "$BUNDLE_ID" ]] || { echo "Could not read PRODUCT_BUNDLE_IDENTIFIER of IMMPhone" >&2; exit 1; }
  SIGNING_OPTIONS="	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Apple Distribution</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>$BUNDLE_ID</key>
		<string>$IMM_PHONE_PROFILE</string>
	</dict>"
else
  ARCHIVE_FLAGS=(-allowProvisioningUpdates ${AUTH_FLAGS[@]+"${AUTH_FLAGS[@]}"})
  EXPORT_FLAGS=(-allowProvisioningUpdates)
fi
EXPORT_FLAGS+=(${AUTH_FLAGS[@]+"${AUTH_FLAGS[@]}"})

cat >"$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$DESTINATION</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
$SIGNING_OPTIONS
</dict>
</plist>
EOF

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Archiving (Release)"
xcodebuild archive \
  -project IMM.xcodeproj \
  -scheme IMMPhone \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED" \
  ${ARCHIVE_FLAGS[@]+"${ARCHIVE_FLAGS[@]}"} \
  "${BUILD_SETTINGS[@]}"

APP="$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -name '*.app' -type d | head -n 1)"
[[ -n "$APP" ]] || { echo "Archive contains no app under $ARCHIVE/Products/Applications" >&2; exit 1; }

echo "==> Checking entitlements (Keychain access group)"
codesign --verify --strict --verbose=2 "$APP"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q 'keychain-access-groups' \
  || { echo "Missing entitlement: keychain-access-groups" >&2; exit 1; }

if [[ $UPLOAD -eq 1 ]]; then
  echo "==> Exporting and uploading to App Store Connect"
else
  echo "==> Exporting (App Store)"
fi
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$OUT" \
  ${EXPORT_FLAGS[@]+"${EXPORT_FLAGS[@]}"}

echo
if [[ $UPLOAD -eq 1 ]]; then
  echo "Done. IMM $VERSION ($BUILD) was sent to App Store Connect; it shows up in TestFlight once processing finishes."
else
  IPA="$(find "$OUT" -maxdepth 1 -name '*.ipa' | head -n 1)"
  [[ -n "$IPA" ]] || { echo "Export did not produce an .ipa in $OUT" >&2; exit 1; }
  echo "Done. $IPA"
fi
