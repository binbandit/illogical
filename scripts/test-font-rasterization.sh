#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/font-clarity
swiftc -O -import-objc-header illogical/Terminal/Bridge.h \
  illogical/Terminal/TerminalFont.swift illogical/Terminal/TerminalTextRuns.swift \
  illogical/Terminal/TerminalFontOptions.swift illogical/Terminal/TerminalCellDrawing.swift \
  tests/TerminalFontRasterizationTests.swift -o .build/font-clarity/rasterization-tests
.build/font-clarity/rasterization-tests
