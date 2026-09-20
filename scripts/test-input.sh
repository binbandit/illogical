#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/tests/input
clang -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal -c illogical/Terminal/Bridge.c -o .build/tests/input/Bridge.o
clang -mmacosx-version-min=15.0 -I illogical/Terminal -c tests/InputPTY.c -o .build/tests/input/InputPTY.o
swiftc -swift-version 5 -target arm64-apple-macos15 -I illogical/Terminal -import-objc-header tests/InputPTY.h \
  illogical/Terminal/TerminalEngine.swift illogical/Appearance/Theme.swift illogical/Model/Protocol.swift tests/TerminalInputTests.swift \
  .build/tests/input/Bridge.o .build/tests/input/InputPTY.o .build/ghostty/lib/libghostty-vt.a -o .build/tests/input/terminal-input-tests
.build/tests/input/terminal-input-tests
swiftc -swift-version 5 -target arm64-apple-macos15 -I illogical/Terminal -import-objc-header illogical/Terminal/Bridge.h \
  illogical/Terminal/TerminalEngine.swift illogical/Terminal/TerminalSurface.swift illogical/Terminal/MetalRenderer.swift illogical/Terminal/TerminalPresentationState.swift \
  illogical/Terminal/TerminalFont.swift illogical/Terminal/TerminalTextRuns.swift illogical/Terminal/TerminalFontOptions.swift illogical/Terminal/TerminalCellGeometry.swift illogical/Terminal/TerminalCellDrawing.swift \
  illogical/Appearance/ContrastCorrection.swift illogical/Appearance/Theme.swift illogical/Model/Protocol.swift \
  illogical/LaunchMetrics.swift tests/TerminalSurfaceInputTests.swift \
  .build/tests/input/Bridge.o .build/ghostty/lib/libghostty-vt.a -o .build/tests/input/terminal-surface-input-tests
.build/tests/input/terminal-surface-input-tests
