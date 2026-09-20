#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/tests/graphics
clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=15.0 -I .build/ghostty/include \
  tests/terminal_graphics_fixture.c .build/ghostty/lib/libghostty-vt.a -o .build/tests/graphics/fixture
.build/tests/graphics/fixture
clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal \
  -c illogical/Terminal/Bridge.c -o .build/tests/graphics/Bridge.o
swiftc -O -swift-version 5 -target arm64-apple-macos15 -import-objc-header illogical/Terminal/Bridge.h \
  illogical/Terminal/TerminalEngine.swift illogical/Appearance/Theme.swift illogical/Model/Protocol.swift tests/TerminalGraphicsTests.swift \
  .build/tests/graphics/Bridge.o .build/ghostty/lib/libghostty-vt.a -o .build/tests/graphics/graphics-tests
.build/tests/graphics/graphics-tests
