#!/usr/bin/env bash
# Builds distributable models:
#   build/ACF.rbxm        library only (ReplicatedStorage.ACFShared + ServerScriptService.ACF)
#   build/ACF-Tests.rbxl  place with library, tests and examples for running the suite in Studio
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
./.bin/rojo.exe build default.project.json -o build/ACF.rbxl
./.bin/rojo.exe build test.project.json -o build/ACF-Tests.rbxl
echo "built build/ACF.rbxl and build/ACF-Tests.rbxl"
