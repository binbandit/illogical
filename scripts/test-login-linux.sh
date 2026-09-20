#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$ROOT/.build/login-linux-test"
mkdir -p "$OUT"
# All PAM configuration, accounts and setuid bits exist only in this disposable
# container. The workspace mount is read-only and no host socket is mounted.
docker run --rm \
  --mount "type=bind,src=$ROOT,dst=/work,readonly" \
  --mount "type=bind,src=$OUT,dst=/out" \
  rust:1.98.0-slim sh -ec '
    apt-get update -qq
    apt-get install -y -qq libpam0g-dev python3 > /out/setup.log 2>&1
    cc -std=c11 -O2 -Wall -Wextra -Werror /work/deploy/linux/illogical-login.c -lpam -o /out/illogical-login
    python3 /work/tests/login_pam_fixture.py
  ' | tee "$OUT/results.json"
