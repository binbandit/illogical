#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=${1:-"$ROOT/.build/dependencies/ghostty"}
# Exact files from 27e8b3fa85d9cf8c7cd5ae2ced348bcb0a4fba9c or their patched
# versions. Refuse to modify an unknown source, including stale cached sources.
apply_patch() {
    HASH=$(shasum -a 256 "$SOURCE/src/terminal/kitty/$1" | cut -d ' ' -f 1)
    case "$HASH" in
        "$2") patch -d "$SOURCE" -p1 < "$ROOT/patches/$4" ;;
        "$3") ;;
        *) echo "Ghostty $1 differs from the pinned revision; review its resource patch." >&2; exit 1 ;;
    esac
}
apply_patch graphics_image.zig \
    4cbefd0e7122b6c378c4ac5d65ad16014f38a74f528cd958311b10757f3e2903 \
    bd15764dbf9dfcc74cf603b4b90aeedc397109eee8773a644bf00d16ffc072cf \
    ghostty-image-budget.patch
apply_patch graphics_storage.zig \
    a2c29c02531f00b939485a9e45eeb8198d55648f116282c31e37bed84677328d \
    4367af0d6005f50024da9591e0d1fcc2348828d44299404b6675ead9765356aa \
    ghostty-image-count.patch
apply_patch graphics_exec.zig \
    617587c5edd81699029ae726436abf01a2852ed06598fea8ad4456a1bb99e8e2 \
    7f3f533e5db4c71a58e45dfc4b8c4fa77b4f5ddafa6e4e60a0d030af461c30a4 \
    ghostty-static-images.patch
