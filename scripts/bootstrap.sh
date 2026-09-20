#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
GHOSTTY=27e8b3fa85d9cf8c7cd5ae2ced348bcb0a4fba9c
ZIG_VERSION=0.16.0
case "$(uname -m)" in
    arm64) ZIG_ARCH=aarch64; ZIG_SHA=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489 ;;
    *) echo 'This build currently supports Apple Silicon. Intel needs a matching Ghostty library.' >&2; exit 1 ;;
esac
command -v go >/dev/null || { echo 'Install Go 1.27.1 or newer first.' >&2; exit 1; }
command -v pkg-config >/dev/null || { echo 'Install pkg-config first.' >&2; exit 1; }
mkdir -p "$ROOT/.build/dependencies"
cd "$ROOT/.build/dependencies"
if [ ! -x "zig-$ZIG_ARCH-macos-$ZIG_VERSION/zig" ]; then
    curl --fail --location --retry 3 "https://ziglang.org/download/$ZIG_VERSION/zig-$ZIG_ARCH-macos-$ZIG_VERSION.tar.xz" -o zig.tar.xz
    printf '%s  %s\n' "$ZIG_SHA" zig.tar.xz | shasum -a 256 -c -
    tar -xf zig.tar.xz
fi
if [ ! -d ghostty ]; then
    curl --fail --location --retry 3 "https://codeload.github.com/ghostty-org/ghostty/tar.gz/$GHOSTTY" -o ghostty.tar.gz
    mkdir ghostty
    tar -xzf ghostty.tar.gz --strip-components=1 -C ghostty
fi
cd ghostty
sh "$ROOT/scripts/apply-ghostty-patches.sh" "$PWD"
"../zig-$ZIG_ARCH-macos-$ZIG_VERSION/zig" build -Dtarget=aarch64-macos.15.0 -Demit-lib-vt -Dapp-runtime=none -Demit-macos-app=false -Doptimize=ReleaseFast --prefix "$ROOT/.build/ghostty"
