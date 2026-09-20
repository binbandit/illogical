#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/contextual-shaping
swiftc -O -import-objc-header illogical/Terminal/Bridge.h \
  illogical/Terminal/TerminalTextRuns.swift illogical/Terminal/TerminalFont.swift \
  illogical/Terminal/TerminalFontOptions.swift illogical/Terminal/TerminalCellDrawing.swift \
  tests/TerminalTextRunsTests.swift -o .build/contextual-shaping/run-tests
.build/contextual-shaping/run-tests
