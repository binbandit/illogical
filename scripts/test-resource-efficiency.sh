#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/resource-efficiency
clang -O2 -Wall -Wextra -Werror tests/resource_usage_probe.c -o .build/resource-efficiency/resource-usage
clang -O2 -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal \
  -c illogical/Terminal/Bridge.c -o .build/resource-efficiency/Bridge.o
clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=15.0 -I illogical/Terminal \
  -c tests/ResourceConnectionFixture.c -o .build/resource-efficiency/RetryFixture.o
swiftc -O -swift-version 5 -default-isolation MainActor -target arm64-apple-macos15 -I illogical/Terminal \
  -import-objc-header tests/ResourceConnectionFixture.h \
  illogical/Model/Protocol.swift illogical/Model/JSONLineFramer.swift illogical/Model/InboundMailbox.swift \
  illogical/Model/ServiceConnection.swift tests/ResourceConnectionRetryTests.swift \
  .build/resource-efficiency/Bridge.o .build/resource-efficiency/RetryFixture.o .build/ghostty/lib/libghostty-vt.a \
  -o .build/resource-efficiency/retry-tests
.build/resource-efficiency/retry-tests
cat > .build/resource-efficiency/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.illogical.resource-tests</string></dict></plist>
PLIST
swiftc -O -swift-version 5 -default-isolation MainActor -target arm64-apple-macos15 -I illogical/Terminal \
  -import-objc-header tests/ResourceConnectionFixture.h \
  illogical/Model/Protocol.swift illogical/Model/JSONLineFramer.swift illogical/Model/InboundMailbox.swift \
  illogical/Model/ServiceConnection.swift illogical/Model/WorkspaceModel.swift illogical/Model/TerminalSearchState.swift \
  illogical/Appearance/Theme.swift illogical/Appearance/GhosttyThemeImporter.swift \
  illogical/Terminal/TerminalFontOptions.swift illogical/Terminal/TerminalEngine.swift tests/WorkspaceResourceTests.swift \
  .build/resource-efficiency/Bridge.o .build/resource-efficiency/RetryFixture.o .build/ghostty/lib/libghostty-vt.a \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker .build/resource-efficiency/Info.plist \
  -o .build/resource-efficiency/workspace-tests
.build/resource-efficiency/workspace-tests
