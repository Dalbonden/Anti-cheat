#!/usr/bin/env bash
# Strict type-check of src/ and examples/ with luau-lsp, Roblox definitions and a Rojo sourcemap.
set -euo pipefail
cd "$(dirname "$0")/.."
./.bin/rojo.exe sourcemap test.project.json -o sourcemap.json
./.bin/luau-lsp.exe analyze --sourcemap=sourcemap.json --definitions=.bin/globalTypes.d.luau --platform=roblox src examples
echo "type check passed"
