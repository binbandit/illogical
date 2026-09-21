#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
REPO=$(mktemp -d)
trap 'rm -rf "$REPO"' EXIT HUP INT TERM
git init -q "$REPO"
cd "$REPO"
git config user.name 'Release test'
git config user.email 'release-test@example.com'
git config commit.gpgsign false
git config tag.gpgsign false

commit() {
    git -c core.hooksPath=/dev/null commit -q --allow-empty -m "$1"
}

expect() {
    ACTUAL=$("$ROOT/scripts/next-version.sh" "$REPO")
    if [ "$ACTUAL" != "$1" ]; then
        printf 'FAIL: %s: expected "%s", got "%s"\n' "$2" "$1" "$ACTUAL" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$2"
}

commit 'chore: initialize'
expect '' 'no releasable commits'
commit 'feat: initial feature'
expect '0.1.0' 'first release'
git tag v0.1.0
expect '' 'already released'
commit 'fix(rendering): sharpen terminal text'
expect '0.1.1' 'patch after a lightweight tag'

# Recreate the failure: the release tag remains on the old history after rewrite.
git checkout -q --detach v0.1.0
commit 'ci: release workflow before rewrite'
git tag v0.1.1
git checkout -q --detach HEAD~1
commit 'ci: release workflow after rewrite'
commit 'fix: repair rendering'
expect '0.1.2' 'release tag outside HEAD ancestry'

git tag v0.1.2
commit 'docs: clarify downloads'
expect '' 'documentation does not release'
commit 'feat(workspace): rename sessions'
expect '0.2.0' 'feature takes precedence over patches'
git tag -a v0.2.0 -m 'Release 0.2.0'
commit 'perf: reduce redraws'
expect '0.2.1' 'patch after an annotated tag'
git tag v0.9.0
git tag v0.10.0
git tag v99.0.0-rc.1
git tag v-next
commit 'revert: restore rendering'
expect '0.10.1' 'numeric version order and stable tags only'
commit 'feat(api)!: change protocol'
expect '1.0.0' 'breaking subject takes precedence'
git tag v1.0.0
commit 'fix: change protocol

BREAKING CHANGE: old clients are unsupported'
expect '2.0.0' 'breaking footer'
