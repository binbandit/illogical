#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
[ "$(uname -s)" = Darwin ] || { echo 'The macOS app can only be packaged on macOS.' >&2; exit 1; }

VERSION=${ILLOGICAL_VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo 0.0.0)}
VERSION=${VERSION#v}
SOURCE=${ILLOGICAL_APP:-$ROOT/.build/xcode/Build/Products/Release/illogical.app}
OUT=${ILLOGICAL_RELEASE_DIR:-$ROOT/.build/release}
NAME=illogical-$VERSION-macos-arm64
STAGING=$OUT/$NAME
APP=$STAGING/illogical.app

[ -x "$SOURCE/Contents/MacOS/illogical" ] && [ -x "$SOURCE/Contents/Resources/bin/illogical" ] || {
    echo 'Build the Release app first: CONFIGURATION=Release ./scripts/build.sh' >&2; exit 1;
}

NOTARIZE=no
if [ -n "${ILLOGICAL_SIGN_IDENTITY:-}" ] && [ -n "${APPLE_ID:-}" ] &&
    [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then NOTARIZE=yes; fi

archive() {
    rm -f "$STAGING.zip"
    /usr/bin/ditto -c -k --keepParent "$APP" "$STAGING.zip"
}
notarize() {
    STATUS=$(xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_PASSWORD" --wait --output-format json |
        sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p' | tail -1)
    [ "$STATUS" = Accepted ] || { echo "Notarization of $1 returned ${STATUS:-no status}." >&2; exit 1; }
    xcrun stapler staple "$2"
}

rm -rf "$STAGING" "$STAGING.zip" "$STAGING.dmg"
mkdir -p "$STAGING"
/usr/bin/ditto "$SOURCE" "$APP"

if [ -n "${ILLOGICAL_SIGN_IDENTITY:-}" ]; then
    # Distribution needs the hardened runtime and a secure timestamp on both
    # executables; the development build signs them ad hoc without either.
    /usr/bin/codesign --force --options runtime --timestamp \
        --sign "$ILLOGICAL_SIGN_IDENTITY" "$APP/Contents/Resources/bin/illogical"
    /usr/bin/codesign --force --options runtime --timestamp \
        --sign "$ILLOGICAL_SIGN_IDENTITY" "$APP"
fi
/usr/bin/codesign --verify --deep --strict "$APP"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = dev.illogical.app ] || {
    echo 'The source is not a production illogical app bundle.' >&2; exit 1;
}
"$APP/Contents/Resources/bin/illogical" help >/dev/null

archive
if [ "$NOTARIZE" = yes ]; then
    notarize "$STAGING.zip" "$APP"
    # Re-archive so the download carries the stapled ticket.
    archive
fi

ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "illogical $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$STAGING.dmg"
if [ "$NOTARIZE" = yes ]; then notarize "$STAGING.dmg" "$STAGING.dmg"; fi

rm -rf "$STAGING"
echo "Packaged $STAGING.dmg"
echo "Packaged $STAGING.zip"
[ "$NOTARIZE" = yes ] || echo 'Not notarized: macOS will quarantine this build until the user clears it.'
