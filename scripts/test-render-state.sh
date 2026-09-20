#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/tests/render-state
clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal \
  -c illogical/Terminal/Bridge.c -o .build/tests/render-state/Bridge.o
clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal \
  tests/terminal_render_state_test.c .build/tests/render-state/Bridge.o .build/ghostty/lib/libghostty-vt.a -o .build/tests/render-state/render-state-tests
.build/tests/render-state/render-state-tests
swiftc -swift-version 5 -target arm64-apple-macos15 -import-objc-header illogical/Terminal/Bridge.h \
  illogical/Terminal/TerminalEngine.swift illogical/Appearance/Theme.swift illogical/Model/Protocol.swift tests/TerminalRenderHoldTests.swift \
  .build/tests/render-state/Bridge.o .build/ghostty/lib/libghostty-vt.a -o .build/tests/render-state/render-deadline-tests
.build/tests/render-state/render-deadline-tests
