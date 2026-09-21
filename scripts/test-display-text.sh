#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/display-text
RENDER_SANITIZER_FLAGS=
if [ "${ILLOGICAL_RENDER_SANITIZE:-0}" = 1 ]; then
  RENDER_SANITIZER_FLAGS=-fsanitize=address
fi
xcrun -sdk macosx metal -c illogical/Terminal/Terminal.metal -o .build/display-text/Terminal.air
xcrun -sdk macosx metallib .build/display-text/Terminal.air -o .build/display-text/default.metallib
cat illogical/Terminal/MetalRenderer.swift tests/display-text-test.swift > .build/display-text/DisplayText.swift
clang $RENDER_SANITIZER_FLAGS -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal -c illogical/Terminal/Bridge.c -o .build/display-text/Bridge.o
SWIFT_RENDER_SANITIZER_FLAGS=
if [ "${ILLOGICAL_RENDER_SANITIZE:-0}" = 1 ]; then
  SWIFT_RENDER_SANITIZER_FLAGS=-sanitize=address
fi
swiftc $SWIFT_RENDER_SANITIZER_FLAGS -O -whole-module-optimization -swift-version 5 -target arm64-apple-macos15 -I illogical/Terminal -import-objc-header illogical/Terminal/Bridge.h \
  .build/display-text/DisplayText.swift illogical/Terminal/TerminalPresentationState.swift illogical/Terminal/TerminalEngine.swift \
  illogical/Terminal/TerminalFont.swift illogical/Terminal/TerminalTextRuns.swift illogical/Terminal/TerminalFontOptions.swift illogical/Terminal/TerminalCellGeometry.swift illogical/Terminal/TerminalCellDrawing.swift \
  illogical/Appearance/ContrastCorrection.swift illogical/Appearance/Theme.swift illogical/Model/Protocol.swift illogical/LaunchMetrics.swift \
  .build/display-text/Bridge.o .build/ghostty/lib/libghostty-vt.a -o .build/display-text/display-text-test
.build/display-text/display-text-test
