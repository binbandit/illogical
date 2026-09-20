#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/tests/workspace-search
clang -O2 -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal \
  -c illogical/Terminal/Bridge.c -o .build/tests/workspace-search/Bridge.o
cat > .build/tests/workspace-search/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.illogical.search-tests</string></dict></plist>
PLIST
swiftc -g -swift-version 5 -default-isolation MainActor -target arm64-apple-macos15 -I illogical/Terminal \
  -import-objc-header illogical/Terminal/Bridge.h \
  illogical/Model/Protocol.swift illogical/Model/JSONLineFramer.swift illogical/Model/InboundMailbox.swift \
  illogical/Model/ServiceConnection.swift illogical/Model/WorkspaceModel.swift illogical/Model/TerminalSearchState.swift \
  illogical/Appearance/Theme.swift illogical/Appearance/GhosttyThemeImporter.swift illogical/Appearance/SearchOverlayPlacement.swift \
  illogical/Terminal/TerminalFontOptions.swift illogical/Terminal/TerminalEngine.swift tests/WorkspaceSearchTests.swift \
  .build/tests/workspace-search/Bridge.o .build/ghostty/lib/libghostty-vt.a \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker .build/tests/workspace-search/Info.plist \
  -o .build/tests/workspace-search/workspace-search-tests
.build/tests/workspace-search/workspace-search-tests
