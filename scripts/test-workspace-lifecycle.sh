#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
OUT=.build/tests/workspace-lifecycle
mkdir -p "$OUT"
clang -O2 -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal -c illogical/Terminal/Bridge.c -o "$OUT/Bridge.o"
clang -O2 -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal -c tests/ResourceConnectionFixture.c -o "$OUT/Fixture.o"
cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.illogical.lifecycle-tests</string></dict></plist>
PLIST
swiftc -g -swift-version 5 -default-isolation MainActor -target arm64-apple-macos15 -I illogical/Terminal \
  -import-objc-header tests/ResourceConnectionFixture.h \
  illogical/Model/*.swift illogical/Appearance/Theme.swift illogical/Appearance/GhosttyThemeImporter.swift \
  illogical/Terminal/TerminalFontOptions.swift illogical/Terminal/TerminalEngine.swift \
  tests/ConnectionFixturePeer.swift tests/WorkspaceLifecycleTests.swift \
  "$OUT/Bridge.o" "$OUT/Fixture.o" .build/ghostty/lib/libghostty-vt.a \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$OUT/Info.plist" \
  -o "$OUT/workspace-lifecycle-tests"
"$OUT/workspace-lifecycle-tests"
