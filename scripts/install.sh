#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "${1:-}" in
    '')
        ./scripts/bootstrap.sh
        CONFIGURATION=Release ./scripts/build.sh
        SOURCE="$ROOT/.build/xcode/Build/Products/Release/illogical.app"
        ;;
    --from)
        [ "$#" -eq 2 ] || { echo 'Usage: install.sh [--from /path/to/illogical.app]' >&2; exit 2; }
        SOURCE=$2
        ;;
    *) echo 'Usage: install.sh [--from /path/to/illogical.app]' >&2; exit 2 ;;
esac

if [ -n "${ILLOGICAL_APP_DIR:-}" ]; then
    APP_DIR=$ILLOGICAL_APP_DIR
elif [ -w /Applications ]; then
    APP_DIR=/Applications
else
    APP_DIR="$HOME/Applications"
fi
BIN_DIR=${ILLOGICAL_BIN_DIR:-"$HOME/.local/bin"}
case "$APP_DIR:$BIN_DIR" in /*:/*) ;; *) echo 'Installation directories must be absolute paths.' >&2; exit 2 ;; esac
DESTINATION="$APP_DIR/illogical.app"
CLI="$DESTINATION/Contents/Resources/bin/illogical"

[ -x "$SOURCE/Contents/MacOS/illogical" ] && [ -x "$SOURCE/Contents/Resources/bin/illogical" ] || {
    echo 'The source must contain the native app and bundled terminal service.' >&2; exit 1;
}
/usr/bin/codesign --verify --deep --strict "$SOURCE"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")" = dev.illogical.app ] || {
    echo 'The source is not a production illogical app bundle.' >&2; exit 1;
}
if [ -e "$BIN_DIR/illogical" ] || [ -L "$BIN_DIR/illogical" ]; then
    [ -L "$BIN_DIR/illogical" ] && [ "$(readlink "$BIN_DIR/illogical")" = "$CLI" ] || {
        echo "Refusing to replace an unrelated command: $BIN_DIR/illogical" >&2; exit 1;
    }
fi
if /bin/ps -axo comm= | /usr/bin/grep -Fxq "$DESTINATION/Contents/MacOS/illogical"; then
    echo 'Quit the installed illogical app and run install again. Its terminal processes will keep running.' >&2
    exit 1
fi
if [ -e "$DESTINATION" ] || [ -L "$DESTINATION" ]; then
    [ ! -L "$DESTINATION" ] && [ -d "$DESTINATION" ] &&
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist" 2>/dev/null)" = dev.illogical.app ] || {
        echo "Refusing to replace an unrelated application: $DESTINATION" >&2; exit 1;
    }
fi

mkdir -p "$APP_DIR" "$BIN_DIR"
STAGING=$(mktemp -d "$APP_DIR/.illogical-install.XXXXXX")
LINK_STAGE="$BIN_DIR/.illogical-install-$$"
INSTALLED=0
cleanup() {
    if [ "$INSTALLED" -eq 0 ] && [ -d "$STAGING/previous.app" ]; then
        if [ -d "$DESTINATION" ]; then mv "$DESTINATION" "$STAGING/failed.app"; fi
        mv "$STAGING/previous.app" "$DESTINATION"
    fi
    rm -f "$LINK_STAGE"
    rm -rf "$STAGING"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/ditto "$SOURCE" "$STAGING/illogical.app"
/usr/bin/codesign --verify --deep --strict "$STAGING/illogical.app"
ln -s "$CLI" "$LINK_STAGE"
if [ -d "$DESTINATION" ]; then mv "$DESTINATION" "$STAGING/previous.app"; fi
mv "$STAGING/illogical.app" "$DESTINATION"
mv -f "$LINK_STAGE" "$BIN_DIR/illogical"
INSTALLED=1
echo "Installed $DESTINATION"
echo "CLI: $BIN_DIR/illogical"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "Add $BIN_DIR to your shell PATH to use the illogical command." ;; esac
echo 'Open illogical from Applications. Existing terminal services and sessions were left running.'
