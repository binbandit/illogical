#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
if [ ! -f .build/ghostty/lib/libghostty-vt.a ]; then ./scripts/bootstrap.sh; fi
# The app targets Apple Silicon, so never build the x86_64 slice that a Release
# configuration would otherwise add.
xcodebuild -project illogical.xcodeproj -scheme illogical -configuration "${CONFIGURATION:-Debug}" -destination 'platform=macOS' -derivedDataPath .build/xcode ARCHS=arm64 CODE_SIGN_IDENTITY=- "$@" build
