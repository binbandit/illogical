#!/bin/sh
# Print the next release version from the Conventional Commits since the last
# v* tag, or nothing when none of them warrants a release. A "!" after the type
# or a BREAKING CHANGE footer bumps the major version, feat bumps the minor
# version, and fix, perf, and revert bump the patch version.
set -eu
cd "${1:-.}"
LAST=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
if [ -n "$LAST" ]; then RANGE="$LAST..HEAD"; else RANGE=HEAD; fi
BASE=${LAST#v}; BASE=${BASE%%-*}; BASE=${BASE:-0.0.0}
# 3 major, 2 minor, 1 patch, 0 none; a commit can only raise the level.
BUMP=0
for COMMIT in $(git rev-list "$RANGE"); do
    SUBJECT=$(git log -1 --format=%s "$COMMIT")
    TYPE=$(printf '%s\n' "$SUBJECT" | sed -n 's/^\([a-zA-Z]*\)\(([^)]*)\)\{0,1\}\(!\{0,1\}\):.*/\1\3/p')
    case "$TYPE" in
        *!) BUMP=3 ;;
        feat) if [ "$BUMP" -lt 2 ]; then BUMP=2; fi ;;
        fix|perf|revert) if [ "$BUMP" -lt 1 ]; then BUMP=1; fi ;;
    esac
    if git log -1 --format=%b "$COMMIT" | grep -Eq '^BREAKING[ -]CHANGE:'; then BUMP=3; fi
    if [ "$BUMP" -eq 3 ]; then break; fi
done
IFS=. read -r MAJOR MINOR PATCH <<EOF
$BASE
EOF
case "$BUMP" in
    3) echo "$((MAJOR + 1)).0.0" ;;
    2) echo "$MAJOR.$((MINOR + 1)).0" ;;
    1) echo "$MAJOR.$MINOR.$((PATCH + 1))" ;;
esac
