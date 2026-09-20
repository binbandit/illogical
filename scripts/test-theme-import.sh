#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/tests/theme-import
clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal \
  -c illogical/Terminal/Bridge.c -o .build/tests/theme-import/Bridge.o
swiftc -O -swift-version 5 -target arm64-apple-macos15 -import-objc-header illogical/Terminal/Bridge.h \
  illogical/Appearance/Theme.swift illogical/Appearance/GhosttyThemeImporter.swift illogical/Appearance/ContrastCorrection.swift \
  illogical/Model/Protocol.swift tests/GhosttyThemeImportTests.swift \
  .build/tests/theme-import/Bridge.o .build/ghostty/lib/libghostty-vt.a -o .build/tests/theme-import/theme-import-tests
.build/tests/theme-import/theme-import-tests
