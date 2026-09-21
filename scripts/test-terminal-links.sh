#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p .build/tests/links
clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=15.0 -I .build/ghostty/include -I illogical/Terminal \
    -c illogical/Terminal/Bridge.c -o .build/tests/links/Bridge.o
for name in links grapheme; do
    clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=15.0 -I illogical/Terminal \
        "tests/terminal_${name}_test.c" .build/tests/links/Bridge.o .build/ghostty/lib/libghostty-vt.a \
        -o ".build/tests/links/terminal-${name}-tests"
    ".build/tests/links/terminal-${name}-tests"
done
