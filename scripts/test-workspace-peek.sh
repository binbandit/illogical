#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/tests/peek
cat > .build/tests/peek/Fixture.h <<'HEADER'
#include "Bridge.h"
#include <ghostty/vt.h>
HEADER
clang -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal -c illogical/Terminal/Bridge.c -o .build/tests/peek/Bridge.o
xcrun -sdk macosx metal -c illogical/Terminal/Terminal.metal -o .build/tests/peek/Terminal.air
xcrun -sdk macosx metallib .build/tests/peek/Terminal.air -o .build/tests/peek/default.metallib
cat > .build/tests/peek/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.illogical.peek-tests</string></dict></plist>
PLIST
swiftc -g -swift-version 5 -target arm64-apple-macos15 -I illogical/Terminal -I .build/ghostty/include -import-objc-header .build/tests/peek/Fixture.h \
  illogical/Terminal/TerminalEngine.swift illogical/Terminal/TerminalSurface.swift illogical/Terminal/MetalRenderer.swift illogical/Terminal/TerminalPresentationState.swift \
  illogical/Terminal/TerminalFont.swift illogical/Terminal/TerminalTextRuns.swift illogical/Terminal/TerminalFontOptions.swift illogical/Terminal/TerminalCellGeometry.swift illogical/Terminal/TerminalCellDrawing.swift \
  illogical/Appearance/ContrastCorrection.swift illogical/Appearance/Theme.swift illogical/Appearance/GhosttyThemeImporter.swift \
  illogical/Model/Protocol.swift illogical/Model/JSONLineFramer.swift illogical/Model/InboundMailbox.swift illogical/Model/ServiceConnection.swift illogical/Model/WorkspaceModel.swift illogical/Model/TerminalSearchState.swift \
  illogical/LaunchMetrics.swift tests/WorkspacePeekTests.swift \
  .build/tests/peek/Bridge.o .build/ghostty/lib/libghostty-vt.a \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker .build/tests/peek/Info.plist \
  -o .build/tests/peek/workspace-peek-tests
.build/tests/peek/workspace-peek-tests
