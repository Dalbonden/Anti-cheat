#!/usr/bin/env bash
# Hot-path micro-benchmarks under Lune (indicative, not Roblox server numbers).
set -euo pipefail
cd "$(dirname "$0")/.."
./.bin/lune.exe run tests/lune/bench.luau
