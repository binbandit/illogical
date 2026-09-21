#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/tests/display
cat > .build/tests/display/Fixture.h <<'HEADER'
#include "Bridge.h"
#include <ghostty/vt.h>
HEADER
clang -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal \
  -c illogical/Terminal/Bridge.c -o .build/tests/display/Bridge.o
xcrun -sdk macosx metal -c illogical/Terminal/Terminal.metal -o .build/tests/display/Terminal.air
xcrun -sdk macosx metallib .build/tests/display/Terminal.air -o .build/tests/display/default.metallib
swiftc -O -swift-version 5 -target arm64-apple-macos15 -I illogical/Terminal -I .build/ghostty/include -import-objc-header .build/tests/display/Fixture.h \
  illogical/Terminal/TerminalEngine.swift illogical/Terminal/TerminalSurface.swift illogical/Terminal/MetalRenderer.swift illogical/Terminal/TerminalPresentationState.swift \
  illogical/Terminal/TerminalFont.swift illogical/Terminal/TerminalTextRuns.swift illogical/Terminal/TerminalFontOptions.swift illogical/Terminal/TerminalCellGeometry.swift illogical/Terminal/TerminalCellDrawing.swift \
  illogical/Appearance/ContrastCorrection.swift illogical/Appearance/Theme.swift illogical/Model/Protocol.swift \
  illogical/LaunchMetrics.swift tests/TerminalDisplayTests.swift \
  .build/tests/display/Bridge.o .build/ghostty/lib/libghostty-vt.a -o .build/tests/display/terminal-display-tests
.build/tests/display/terminal-display-tests
