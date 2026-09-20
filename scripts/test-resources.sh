#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/tests/resources
clang -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal \
  -c illogical/Terminal/Bridge.c -o .build/tests/resources/Bridge.o
xcrun -sdk macosx metal -c illogical/Terminal/Terminal.metal -o .build/tests/resources/Terminal.air
xcrun -sdk macosx metallib .build/tests/resources/Terminal.air -o .build/tests/resources/default.metallib
swiftc -O -swift-version 5 -target arm64-apple-macos15 -I illogical/Terminal -import-objc-header illogical/Terminal/Bridge.h \
  illogical/Terminal/TerminalEngine.swift illogical/Terminal/TerminalSurface.swift illogical/Terminal/MetalRenderer.swift illogical/Terminal/TerminalPresentationState.swift \
  illogical/Terminal/TerminalFont.swift illogical/Terminal/TerminalTextRuns.swift illogical/Terminal/TerminalFontOptions.swift illogical/Terminal/TerminalCellGeometry.swift illogical/Terminal/TerminalCellDrawing.swift \
  illogical/Appearance/ContrastCorrection.swift illogical/Appearance/Theme.swift illogical/Model/Protocol.swift \
  illogical/LaunchMetrics.swift tests/TerminalSurfaceResourceTests.swift \
  .build/tests/resources/Bridge.o .build/ghostty/lib/libghostty-vt.a -o .build/tests/resources/terminal-surface-resource-tests
.build/tests/resources/terminal-surface-resource-tests
