#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
[ "$(uname -s)" = Linux ] || { echo 'The Linux service archive can only be built on Linux.' >&2; exit 1; }

VERSION=${ILLOGICAL_VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo 0.0.0)}
VERSION=${VERSION#v}
ARCH=$(uname -m)
OUT=${ILLOGICAL_RELEASE_DIR:-$ROOT/.build/release}
NAME=illogical-service-$VERSION-linux-$ARCH
STAGING=$OUT/$NAME

if [ ! -f .build/ghostty/lib/libghostty-vt.a ]; then ./scripts/bootstrap.sh; fi

rm -rf "$STAGING" "$STAGING.tar.gz"
mkdir -p "$STAGING/bin" "$STAGING/share/illogical"
PKG_CONFIG_PATH="$ROOT/.build/ghostty/share/pkgconfig" CGO_ENABLED=1 \
    go -C service build -trimpath -o "$STAGING/bin/illogical" ./cmd/illogical

# The Linux compile closure differs from the app's, so its notices replace the
# macOS Go module set the way the Nix package does.
cp -R illogical/Resources/Licenses "$STAGING/share/illogical/licenses"
rm -rf "$STAGING/share/illogical/licenses/GoModules"
cp -R deploy/linux/licenses "$STAGING/share/illogical/licenses/GoModules"
cat > "$STAGING/README" <<NOTES
illogical $VERSION - terminal service and CLI for Linux ($ARCH)

This archive holds the service and command line client only. The native
application is macOS. Install a remote host with:

    sudo install -m755 bin/illogical /usr/local/bin/illogical

The service starts on the first connection and keeps its state in
~/.local/share/illogical. Run 'illogical help' for the commands.

Requires glibc 2.34 or newer. The NixOS module and the same-user PAM login
helper are built from the repository flake, not from this archive.
NOTES

"$STAGING/bin/illogical" help >/dev/null
tar -czf "$STAGING.tar.gz" -C "$OUT" "$NAME"
rm -rf "$STAGING"
echo "Packaged $STAGING.tar.gz"
