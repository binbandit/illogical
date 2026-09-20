#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/tests/protocols
clang -Wall -Wextra -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal tests/terminal_protocol_test.c \
  .build/ghostty/lib/libghostty-vt.a -o .build/tests/protocols/terminal-protocol-test
.build/tests/protocols/terminal-protocol-test
clang -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal -c illogical/Terminal/Bridge.c -o .build/tests/protocols/Bridge.o
swiftc -O -swift-version 5 -target arm64-apple-macos15 -I illogical/Terminal -import-objc-header illogical/Terminal/Bridge.h \
  illogical/Terminal/TerminalEngine.swift illogical/Appearance/Theme.swift illogical/Model/Protocol.swift tests/TerminalFocusMouseTests.swift \
  .build/tests/protocols/Bridge.o .build/ghostty/lib/libghostty-vt.a -o .build/tests/protocols/terminal-focus-mouse-test
.build/tests/protocols/terminal-focus-mouse-test
