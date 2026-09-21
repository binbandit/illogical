#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
if [ ! -f .build/ghostty/lib/libghostty-vt.a ]; then ./scripts/bootstrap.sh; fi
xcodebuild -project illogical.xcodeproj -scheme illogical -configuration "${CONFIGURATION:-Debug}" -destination 'platform=macOS' -derivedDataPath .build/xcode CODE_SIGN_IDENTITY=- "$@" build
