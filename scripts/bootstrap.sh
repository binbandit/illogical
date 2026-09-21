#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
GHOSTTY=27e8b3fa85d9cf8c7cd5ae2ced348bcb0a4fba9c
ZIG_VERSION=0.16.0
# Linux hosts build the service and CLI only. The glibc floor keeps the released
# Linux binaries usable on Ubuntu 22.04, Debian 12, and RHEL 9.
case "$(uname -s) $(uname -m)" in
    'Darwin arm64')
        ZIG_HOST=aarch64-macos
        ZIG_SHA=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489
        ZIG_TARGET='-Dtarget=aarch64-macos.15.0 -Demit-macos-app=false'
        ;;
    'Linux x86_64')
        ZIG_HOST=x86_64-linux
        ZIG_SHA=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
        ZIG_TARGET=-Dtarget=x86_64-linux-gnu.2.34
        ;;
    'Linux aarch64')
        ZIG_HOST=aarch64-linux
        ZIG_SHA=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17
        ZIG_TARGET=-Dtarget=aarch64-linux-gnu.2.34
        ;;
    'Darwin '*) echo 'This build currently supports Apple Silicon. Intel needs a matching Ghostty library.' >&2; exit 1 ;;
    *) echo 'Supported hosts are Apple Silicon macOS and x86_64 or aarch64 Linux.' >&2; exit 1 ;;
esac
command -v go >/dev/null || { echo 'Install Go 1.27.1 or newer first.' >&2; exit 1; }
command -v pkg-config >/dev/null || { echo 'Install pkg-config first.' >&2; exit 1; }
mkdir -p "$ROOT/.build/dependencies"
cd "$ROOT/.build/dependencies"
if [ ! -x "zig-$ZIG_HOST-$ZIG_VERSION/zig" ]; then
    curl --fail --location --retry 3 "https://ziglang.org/download/$ZIG_VERSION/zig-$ZIG_HOST-$ZIG_VERSION.tar.xz" -o zig.tar.xz
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
# shellcheck disable=SC2086 # ZIG_TARGET carries separate options.
"../zig-$ZIG_HOST-$ZIG_VERSION/zig" build $ZIG_TARGET -Demit-lib-vt -Dapp-runtime=none -Doptimize=ReleaseFast --prefix "$ROOT/.build/ghostty"
