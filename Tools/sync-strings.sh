#!/usr/bin/env bash
# Fills Packages/IMMKit/Sources/IMMUI/Resources/Localizable.xcstrings from the strings the compiler
# extracted during the last build (.stringsdata files). xcodebuild extracts but only the Xcode IDE
# writes the catalog, so run this after a build: Tools/sync-strings.sh [derived data dir, default build/dd]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${1:-$ROOT/build/dd}"
CATALOG="$ROOT/Packages/IMMKit/Sources/IMMUI/Resources/Localizable.xcstrings"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Newest configuration only, so strings removed from source go stale instead of lingering.
BUILD_DIR="$(ls -td "$DERIVED"/Build/Intermediates.noindex/IMMKit.build/*/IMMUI*.build 2>/dev/null | head -1)"
[[ -n "$BUILD_DIR" ]] || { echo "No IMMUI build products under $DERIVED; build the app first." >&2; exit 1; }

FILES=()
while IFS= read -r -d '' file; do FILES+=(--stringsdata "$file"); done \
  < <(find "$BUILD_DIR" -name '*.stringsdata' -print0)
[[ ${#FILES[@]} -gt 0 ]] || { echo "No .stringsdata files in $BUILD_DIR" >&2; exit 1; }

xcrun xcstringstool sync "$CATALOG" "${FILES[@]}"
echo "Synced $(( ${#FILES[@]} / 2 )) files into $(jq '.strings | length' "$CATALOG") catalog entries"
