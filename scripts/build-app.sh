#!/bin/bash
# Builds the same app bundle as Xcode, including the icon and privacy manifest.
# Run from anywhere: ./scripts/build-app.sh [debug|release]

set -euo pipefail

REQUESTED="${1:-release}"
case "$REQUESTED" in
    debug) CONFIGURATION="Debug" ;;
    release) CONFIGURATION="Release" ;;
    *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$ROOT/.derivedData"
PRODUCT="$DERIVED/Build/Products/$CONFIGURATION/FileRenamer.app"
APP="$ROOT/build/FileRenamer.app"
XCODEBUILD="/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"

[ -x "$XCODEBUILD" ] || { echo "Xcode is required: /Applications/Xcode.app" >&2; exit 1; }

echo "==> xcodebuild ($CONFIGURATION)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer "$XCODEBUILD" \
    -project "$ROOT/FileRenamer.xcodeproj" \
    -scheme FileRenamer \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    build -quiet

[ -d "$PRODUCT" ] || { echo "app not found at $PRODUCT" >&2; exit 1; }
mkdir -p "$ROOT/build"
rm -rf "$APP"
/usr/bin/ditto "$PRODUCT" "$APP"

echo "==> done: $APP"
echo "    open \"$APP\""
