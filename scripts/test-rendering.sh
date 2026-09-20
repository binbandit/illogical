#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/tests
cp illogical/Resources/Fonts/JetBrainsMonoNerdFont-Regular.ttf .build/tests/JetBrainsMonoNerdFont-Regular.ttf
xcrun -sdk macosx metal -c illogical/Terminal/Terminal.metal -o .build/tests/Terminal.air
xcrun -sdk macosx metallib .build/tests/Terminal.air -o .build/tests/Terminal.metallib
swiftc -O -import-objc-header illogical/Terminal/Bridge.h illogical/Terminal/TerminalFont.swift illogical/Terminal/TerminalTextRuns.swift illogical/Terminal/TerminalFontOptions.swift \
  illogical/Terminal/TerminalCellDrawing.swift illogical/Terminal/TerminalCellGeometry.swift illogical/Terminal/TerminalPresentationState.swift \
  tests/terminal_rendering_test.swift -o .build/tests/terminal_rendering_test
.build/tests/terminal_rendering_test
swiftc illogical/Terminal/TerminalPresentationState.swift tests/TerminalPresentationTests.swift -o .build/tests/terminal-presentation-tests
.build/tests/terminal-presentation-tests
