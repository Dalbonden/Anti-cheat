#!/usr/bin/env bash
# Offline test suite (Lune). Optional argument filters test names by substring.
set -euo pipefail
cd "$(dirname "$0")/.."
./.bin/lune.exe run tests/lune/run.luau "$@"
