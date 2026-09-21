#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$ROOT"

if [ ! -f .build/ghostty/lib/libghostty-vt.a ]; then
    ./scripts/bootstrap.sh
fi
export PKG_CONFIG_PATH="$ROOT/.build/ghostty/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
mkdir -p .build/tests

printf '\nService, PTY, persistence, transport, and race checks\n'
(cd service && go test -race ./...)

printf '\nTerminal bridge checks\n'
clang -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal \
    illogical/Terminal/Bridge.c tests/terminal_bridge_test.c \
    .build/ghostty/lib/libghostty-vt.a -o .build/tests/terminal-bridge-tests
.build/tests/terminal-bridge-tests

printf '\nSynchronized output, dirty rows, and rendering deadline checks\n'
./scripts/test-render-state.sh

printf '\nKeyboard, IME, and foreground-process input checks\n'
./scripts/test-input.sh
./scripts/test-terminal-protocols.sh
./scripts/test-terminal-scrolling.sh
./scripts/test-terminal-links.sh

printf '\nConnection delivery, backpressure, and JSON framing checks\n'
./scripts/test-connection.sh

printf '\nFont, cell geometry, and Metal rendering checks\n'
./scripts/test-rendering.sh
./scripts/test-font-rasterization.sh
./scripts/test-display-text.sh
./scripts/test-display.sh
./scripts/test-text-runs.sh
./scripts/test-graphics.sh

printf '\nIdle cursor and surface resource checks\n'
./scripts/test-resources.sh
./scripts/test-resource-render.sh
./scripts/test-resource-efficiency.sh

printf '\nSearch, contrast, and independent pane search checks\n'
./scripts/test-search-contrast.sh
./scripts/test-workspace-search.sh
./scripts/test-workspace-rename.sh
./scripts/test-workspace-navigation.sh
./scripts/test-theme-import.sh

printf '\nAll checks passed.\n'
