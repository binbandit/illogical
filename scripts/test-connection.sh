#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/tests/connection
swiftc -O -swift-version 5 -default-isolation MainActor -target arm64-apple-macos15 \
  illogical/Model/Protocol.swift illogical/Model/InboundMailbox.swift tests/InboundMailboxTests.swift \
  -o .build/tests/connection/mailbox-tests
.build/tests/connection/mailbox-tests
swiftc -O -swift-version 5 -target arm64-apple-macos15 illogical/Model/JSONLineFramer.swift tests/JSONLineFramerTests.swift \
  -o .build/tests/connection/framing-tests
.build/tests/connection/framing-tests
swiftc -typecheck -swift-version 5 -default-isolation MainActor -target arm64-apple-macos15 \
  -import-objc-header illogical/Terminal/Bridge.h illogical/Model/Protocol.swift illogical/Model/JSONLineFramer.swift \
  illogical/Model/InboundMailbox.swift illogical/Model/ServiceConnection.swift
clang -O2 -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal \
  -c illogical/Terminal/Bridge.c -o .build/tests/connection/Bridge.o
clang -O2 -mmacosx-version-min=15.0 -I illogical/Terminal \
  -c tests/ConnectionFixture.c -o .build/tests/connection/Fixture.o
swiftc -O -swift-version 5 -default-isolation MainActor -target arm64-apple-macos15 -I illogical/Terminal \
  -import-objc-header tests/ConnectionFixture.h illogical/Model/Protocol.swift illogical/Model/JSONLineFramer.swift \
  illogical/Model/InboundMailbox.swift illogical/Model/ServiceConnection.swift tests/ServiceConnectionHandshakeTests.swift \
  .build/tests/connection/Bridge.o .build/tests/connection/Fixture.o .build/ghostty/lib/libghostty-vt.a \
  -o .build/tests/connection/handshake-tests
.build/tests/connection/handshake-tests
mkdir -p .build/tests/connection/bin
clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=15.0 tests/ConnectionBootstrapFixture.c \
  -o .build/tests/connection/bin/illogical
swiftc -O -swift-version 5 -default-isolation MainActor -target arm64-apple-macos15 \
  -import-objc-header illogical/Terminal/Bridge.h illogical/Model/Protocol.swift illogical/Model/JSONLineFramer.swift \
  illogical/Model/InboundMailbox.swift illogical/Model/ServiceConnection.swift tests/ServiceConnectionBootstrapTests.swift \
  .build/tests/connection/Bridge.o .build/ghostty/lib/libghostty-vt.a -o .build/tests/connection/bootstrap-tests
for mode in handoff early unavailable; do
  fixture_socket="/tmp/ilg-bootstrap-$$-$mode.sock"
  ILLOGICAL_SOCKET="$fixture_socket" ILLOGICAL_CONNECTION_TEST_MODE="$mode" \
    ILLOGICAL_CONNECTION_TEST_LOG="$fixture_socket.log" .build/tests/connection/bootstrap-tests
done
swiftc -O -swift-version 5 -default-isolation MainActor -target arm64-apple-macos15 -I illogical/Terminal \
  -import-objc-header tests/ConnectionFixture.h illogical/Model/Protocol.swift illogical/Model/JSONLineFramer.swift \
  illogical/Model/InboundMailbox.swift illogical/Model/ServiceConnection.swift tests/ServiceConnectionOutboundTests.swift \
  .build/tests/connection/Bridge.o .build/tests/connection/Fixture.o .build/ghostty/lib/libghostty-vt.a \
  -o .build/tests/connection/outbound-tests
.build/tests/connection/outbound-tests
