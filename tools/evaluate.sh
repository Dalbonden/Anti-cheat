#!/usr/bin/env bash
# Phase 8 evaluation: detection accuracy, false positives, live enforcement, CPU, memory
# soak, logging. quick (~10 s) or full (~2 min); --write updates docs/EVALUATION.md.
#   tools/evaluate.sh [quick|full] [--write]
set -euo pipefail
cd "$(dirname "$0")/.."
./.bin/lune.exe run tests/lune/evaluate.luau "$@"
