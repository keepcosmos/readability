#!/usr/bin/env bash
# Generates the golden traces of Readability.js into tmp/traces (git-ignored). See
# scripts/traces/README.md.
#
#     scripts/traces.sh [page ...]
#
# 1. tmp/traces/<page>.json: Readability.js on JSDOMParser, exactly as upstream's tests run it.
# 2. tmp/traces/lexbor-input/<page>.json: LazyHTML's tree of each page (needs mix).
# 3. tmp/traces/lexbor/<page>.json: Readability.js on LazyHTML's tree.
set -euo pipefail

cd "$(dirname "$0")/.."

node scripts/traces/trace.js "$@"
MIX_ENV=test mix run scripts/parser_parity.exs --export-only "$@"
node scripts/traces/trace.js --input lexbor "$@"
du -sh tmp/traces | sed 's/^/total size: /'
