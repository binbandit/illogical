#!/bin/sh
# Renders the workspace chrome offscreen in every appearance variant to
# .build/parity/*.png for side-by-side review with the reference frames.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
OUT=.build/tests/chrome-parity
mkdir -p "$OUT"
clang -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal -c illogical/Terminal/Bridge.c -o "$OUT/Bridge.o"
clang -O2 -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal -c tests/ResourceConnectionFixture.c -o "$OUT/Fixture.o"
xcrun -sdk macosx metal -c illogical/Terminal/Terminal.metal -o "$OUT/Terminal.air"
xcrun -sdk macosx metallib "$OUT/Terminal.air" -o "$OUT/default.metallib"
cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.illogical.parity</string></dict></plist>
PLIST
SOURCES=$(find illogical -name '*.swift' ! -name 'MyApp.swift' | sort)
# shellcheck disable=SC2086
swiftc -g -swift-version 5 -default-isolation MainActor -target arm64-apple-macos15 \
  -I illogical/Terminal -I .build/ghostty/include -import-objc-header tests/ResourceConnectionFixture.h \
  $SOURCES tests/ConnectionFixturePeer.swift tests/ChromeParity.swift \
  "$OUT/Bridge.o" "$OUT/Fixture.o" .build/ghostty/lib/libghostty-vt.a -lc++ \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$OUT/Info.plist" \
  -o "$OUT/chrome-parity"
"$OUT/chrome-parity" "${1:-.build/parity}"
