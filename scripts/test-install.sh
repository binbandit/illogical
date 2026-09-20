#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/.build/xcode/Build/Products/Release/illogical.app"
FIXTURE=$(mktemp -d /tmp/illogical-install-test.XXXXXX)
trap 'rm -rf "$FIXTURE"' EXIT
export ILLOGICAL_APP_DIR="$FIXTURE/Applications With Spaces"
export ILLOGICAL_BIN_DIR="$FIXTURE/CLI With Spaces"
"$ROOT/scripts/install.sh" --from "$SOURCE"
cmp "$SOURCE/Contents/MacOS/illogical" "$ILLOGICAL_APP_DIR/illogical.app/Contents/MacOS/illogical"
"$ILLOGICAL_BIN_DIR/illogical" help > "$FIXTURE/help.txt"
test -s "$FIXTURE/help.txt"
# Updating replaces the bundle while keeping the stable CLI path usable.
touch "$ILLOGICAL_APP_DIR/illogical.app/stale-install-marker"
"$ROOT/scripts/install.sh" --from "$SOURCE"
test ! -e "$ILLOGICAL_APP_DIR/illogical.app/stale-install-marker"
test -x "$ILLOGICAL_BIN_DIR/illogical"
rm "$ILLOGICAL_BIN_DIR/illogical"
printf 'existing command\n' > "$ILLOGICAL_BIN_DIR/illogical"
if "$ROOT/scripts/install.sh" --from "$SOURCE" > "$FIXTURE/collision.txt" 2>&1; then
    echo 'Installer overwrote an unrelated CLI.' >&2; exit 1
fi
test "$(cat "$ILLOGICAL_BIN_DIR/illogical")" = 'existing command'
test -x "$ILLOGICAL_APP_DIR/illogical.app/Contents/MacOS/illogical"
echo 'Installation passed: signed bundle, working CLI, paths with spaces, replacement, and collision protection.'
