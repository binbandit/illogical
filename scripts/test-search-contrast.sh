#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/tests/search-contrast
clang -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal -c illogical/Terminal/Bridge.c -o .build/tests/search-contrast/Bridge.o
clang -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal tests/terminal_search_test.c \
  .build/tests/search-contrast/Bridge.o .build/ghostty/lib/libghostty-vt.a -o .build/tests/search-contrast/terminal-search-test
.build/tests/search-contrast/terminal-search-test
swiftc -O -swift-version 5 -target arm64-apple-macos15 -I illogical/Terminal -import-objc-header illogical/Terminal/Bridge.h \
  illogical/Terminal/TerminalEngine.swift illogical/Appearance/ContrastCorrection.swift illogical/Appearance/Theme.swift illogical/Model/Protocol.swift \
  tests/TerminalSearchContrastTests.swift .build/tests/search-contrast/Bridge.o .build/ghostty/lib/libghostty-vt.a -o .build/tests/search-contrast/terminal-search-contrast-tests
.build/tests/search-contrast/terminal-search-contrast-tests
swiftc -g -swift-version 5 -target arm64-apple-macos15 -I illogical/Terminal -import-objc-header illogical/Terminal/Bridge.h \
  illogical/Terminal/TerminalEngine.swift illogical/Appearance/Theme.swift illogical/Model/Protocol.swift illogical/Model/InboundMailbox.swift \
  tests/TerminalReplayTests.swift .build/tests/search-contrast/Bridge.o .build/ghostty/lib/libghostty-vt.a -o .build/tests/search-contrast/terminal-replay-tests
.build/tests/search-contrast/terminal-replay-tests
