#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/tests
# Bundled fonts resolve next to the executable, as in the app bundle.
cp illogical/Resources/Fonts/JetBrainsMonoNerdFont-*.ttf .build/tests/
swiftc -O -import-objc-header illogical/Terminal/Bridge.h illogical/Terminal/TerminalFont.swift illogical/Terminal/TerminalTextRuns.swift \
  illogical/Terminal/TerminalFontOptions.swift illogical/Terminal/TerminalCellDrawing.swift illogical/Terminal/TerminalCellGeometry.swift \
  tests/terminal_rendering_test.swift -o .build/tests/terminal_rendering_test
.build/tests/terminal_rendering_test
swiftc illogical/Terminal/TerminalPresentationState.swift tests/TerminalPresentationTests.swift -o .build/tests/terminal-presentation-tests
.build/tests/terminal-presentation-tests
