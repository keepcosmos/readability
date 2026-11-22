#!/usr/bin/env bash
# Vendors Mozilla Readability.js's test pages into test/fixtures/readability_js.
#
#     scripts/sync_readability_js.sh [commit]
#
# The pages are the conformance oracle for the port. Bump the pinned commit
# deliberately, re-run the suite, and update test/fixtures/readability_js/known_failures.txt.
set -euo pipefail

COMMIT="${1:-ab4027a8b37669745016869a37a504727992b2ba}"
REPO="https://github.com/mozilla/readability.git"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/test/fixtures/readability_js"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git -C "$TMP" init -q
git -C "$TMP" remote add origin "$REPO"
git -C "$TMP" fetch -q --depth 1 origin "$COMMIT"
git -C "$TMP" checkout -q FETCH_HEAD

rm -rf "$DEST/pages"
mkdir -p "$DEST/pages"
cp -R "$TMP/test/test-pages/." "$DEST/pages/"
cp "$TMP/LICENSE.md" "$DEST/LICENSE.md"
echo "$COMMIT" > "$DEST/COMMIT"

echo "Synced $(ls "$DEST/pages" | wc -l | tr -d ' ') pages from mozilla/readability@${COMMIT:0:7}"
