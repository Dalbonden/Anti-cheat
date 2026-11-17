#!/usr/bin/env bash
# Pre-commit gate: tests, strict type check and build. Exits non-zero on the first failure.
set -euo pipefail
cd "$(dirname "$0")/.."
./tools/test.sh
./tools/check.sh
./tools/build.sh
echo "VERIFY OK"
