#!/bin/bash
# Creates a Developer ID signed, notarized DMG for distribution outside the Mac App Store.
#
# One-time credential setup:
#   xcrun notarytool store-credentials "FileRenamer-Notary" \
#     --apple-id "YOUR_APPLE_ID" --team-id "6HY8YSMK7C"
#
# Final release:
#   ./scripts/build-dmg.sh
#
# Local packaging check (never distribute this output):
#   ./scripts/build-dmg.sh --skip-notarization

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/FileRenamer.xcodeproj"
SCHEME="FileRenamer"
TEAM_ID="${DEVELOPMENT_TEAM:-6HY8YSMK7C}"
IDENTITY="${DEVELOPER_ID_APPLICATION:-Developer ID Application: Keiju Hiramoto (6HY8YSMK7C)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-FileRenamer-Notary}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/build/distribution}"
SKIP_NOTARIZATION=0
UPDATE_DOWNLOAD_URL_PREFIX="${UPDATE_DOWNLOAD_URL_PREFIX:-https://github.com/hirakke/FileRenamer/releases/download}"
RELEASE_NOTES_URL="${RELEASE_NOTES_URL:-https://hirakke.github.io/FileRenamer/release-notes.html}"

DEVELOPER_DIR_PATH="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
XCODEBUILD="$DEVELOPER_DIR_PATH/usr/bin/xcodebuild"

usage() {
    cat <<'USAGE'
usage: ./scripts/build-dmg.sh [options]

Options:
  --notary-profile NAME   Keychain profile created by notarytool
                          (default: FileRenamer-Notary)
  --output DIR            Output directory (default: build/distribution)
  --skip-notarization     Build an explicitly marked local-test DMG only
  -h, --help              Show this help

Environment overrides:
  DEVELOPMENT_TEAM
  DEVELOPER_ID_APPLICATION
  NOTARY_PROFILE
  OUTPUT_DIR
  UPDATE_DOWNLOAD_URL_PREFIX
  RELEASE_NOTES_URL
  DEVELOPER_DIR
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --notary-profile)
            [ "$#" -ge 2 ] || { echo "missing value for --notary-profile" >&2; exit 2; }
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || { echo "missing value for --output" >&2; exit 2; }
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --skip-notarization)
            SKIP_NOTARIZATION=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[ -x "$XCODEBUILD" ] || {
    echo "Xcode is required at: $DEVELOPER_DIR_PATH" >&2
    exit 1
}

/usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq "\"$IDENTITY\"" || {
    echo "Developer ID identity not found in the active keychain:" >&2
    echo "  $IDENTITY" >&2
    echo "Install the certificate with its private key, then try again." >&2
    exit 1
}

/bin/mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/FileRenamer-dmg.XXXXXX)"
ARCHIVE_PATH="$WORK_DIR/FileRenamer.xcarchive"
DERIVED_DATA_PATH="$WORK_DIR/DerivedData"
STAGING_DIR="$WORK_DIR/staging"
MOUNT_POINT="$WORK_DIR/mount"
IS_MOUNTED=0

cleanup() {
    if [ "$IS_MOUNTED" -eq 1 ]; then
        /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
    fi
    case "$WORK_DIR" in
        /private/tmp/FileRenamer-dmg.*) /bin/rm -rf "$WORK_DIR" ;;
    esac
}
trap cleanup EXIT INT TERM

echo "==> Archiving universal Release build"
DEVELOPER_DIR="$DEVELOPER_DIR_PATH" "$XCODEBUILD" \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    archive

APP="$ARCHIVE_PATH/Products/Applications/FileRenamer.app"
[ -d "$APP" ] || { echo "archived app not found: $APP" >&2; exit 1; }

echo "==> Verifying app signature"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
SIGNING_INFO="$(/usr/bin/codesign --display --verbose=4 "$APP" 2>&1)"
printf '%s\n' "$SIGNING_INFO" | /usr/bin/grep -Fq "Authority=$IDENTITY" || {
    echo "archive was not signed by the expected Developer ID identity" >&2
    exit 1
}

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$APP/Contents/Info.plist")"
SAFE_VERSION="$(printf '%s' "$VERSION" | /usr/bin/tr -cd '[:alnum:]._-')"
[ -n "$SAFE_VERSION" ] || { echo "invalid app version: $VERSION" >&2; exit 1; }
[ "$ICON_NAME" = "FileRenamer" ] || {
    echo "unexpected app icon: $ICON_NAME (expected FileRenamer.icon)" >&2
    exit 1
}
[ -f "$APP/Contents/Resources/FileRenamer.icns" ] || {
    echo "FileRenamer.icon was not compiled into the archived app" >&2
    exit 1
}

/bin/mkdir -p "$STAGING_DIR"
/usr/bin/ditto "$APP" "$STAGING_DIR/FileRenamer.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"

if [ "$SKIP_NOTARIZATION" -eq 1 ]; then
    DMG="$OUTPUT_DIR/FileRenamer-$SAFE_VERSION-unnotarized.dmg"
else
    DMG="$OUTPUT_DIR/FileRenamer-$SAFE_VERSION.dmg"
fi

echo "==> Creating DMG"
/usr/bin/hdiutil create \
    -volname "FileRenamer" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -ov \
    "$DMG"

echo "==> Signing DMG"
/usr/bin/codesign --force --timestamp --sign "$IDENTITY" "$DMG"
/usr/bin/codesign --verify --strict --verbose=2 "$DMG"

if [ "$SKIP_NOTARIZATION" -eq 1 ]; then
    echo "==> Notarization skipped"
    echo "    This DMG is marked unnotarized and must not be distributed."
else
    echo "==> Submitting DMG to Apple notary service"
    /usr/bin/xcrun notarytool submit "$DMG" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    echo "==> Stapling notarization ticket"
    /usr/bin/xcrun stapler staple "$DMG"
    /usr/bin/xcrun stapler validate "$DMG"

    echo "==> Verifying Gatekeeper assessment"
    /usr/sbin/spctl --assess --type open \
        --context context:primary-signature \
        --verbose=4 "$DMG"

    /bin/mkdir -p "$MOUNT_POINT"
    /usr/bin/hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT_POINT" -quiet
    IS_MOUNTED=1
    /usr/sbin/spctl --assess --type execute --verbose=4 "$MOUNT_POINT/FileRenamer.app"
    /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet
    IS_MOUNTED=0
fi

(
    cd "$OUTPUT_DIR"
    DMG_NAME="$(/usr/bin/basename "$DMG")"
    /usr/bin/shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"
)

if [ "$SKIP_NOTARIZATION" -eq 0 ]; then
    SPARKLE_GENERATE_APPCAST="$DERIVED_DATA_PATH/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
    [ -x "$SPARKLE_GENERATE_APPCAST" ] || {
        echo "Sparkle's generate_appcast tool was not found in the resolved package artifacts." >&2
        exit 1
    }

    APPCAST_WORK_DIR="$WORK_DIR/appcast"
    /bin/mkdir -p "$APPCAST_WORK_DIR"
    DMG_NAME="$(/usr/bin/basename "$DMG")"
    DMG_BASENAME="${DMG_NAME%.dmg}"
    /usr/bin/ditto "$DMG" "$APPCAST_WORK_DIR/$DMG_NAME"
    /usr/bin/ditto "$ROOT/docs/release-notes.md" "$APPCAST_WORK_DIR/$DMG_BASENAME.md"

    echo "==> Signing update feed"
    "$SPARKLE_GENERATE_APPCAST" \
        --download-url-prefix "$UPDATE_DOWNLOAD_URL_PREFIX/v$VERSION/" \
        --full-release-notes-url "$RELEASE_NOTES_URL" \
        --link "https://hirakke.github.io/FileRenamer/" \
        --embed-release-notes \
        -o "$APPCAST_WORK_DIR/appcast.xml" \
        "$APPCAST_WORK_DIR"
    /usr/bin/ditto "$APPCAST_WORK_DIR/appcast.xml" "$ROOT/docs/appcast.xml"
fi

echo "==> Complete"
echo "    App version: $VERSION ($BUILD)"
echo "    DMG: $DMG"
echo "    SHA-256: $DMG.sha256"
if [ "$SKIP_NOTARIZATION" -eq 0 ]; then
    echo "    Appcast: $ROOT/docs/appcast.xml"
    echo "    Publish the DMG as GitHub Release asset v$VERSION, then push docs/appcast.xml."
fi
