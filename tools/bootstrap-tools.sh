#!/usr/bin/env bash
# Downloads the pinned toolchain into .bin/ (Windows x64). Rojo and Lune are fetched from
# their GitHub releases; luau-lsp provides type checking.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .bin && cd .bin
fetch() { curl -fsSL -o "$1" "$2"; }
tmp=$(mktemp -d)
fetch "$tmp/rojo.zip" https://github.com/rojo-rbx/rojo/releases/download/v7.7.0/rojo-7.7.0-windows-x86_64.zip
fetch "$tmp/lune.zip" https://github.com/lune-org/lune/releases/download/v0.10.5/lune-0.10.5-windows-x86_64.zip
fetch "$tmp/lsp.zip" https://github.com/JohnnyMorganz/luau-lsp/releases/download/1.70.1/luau-lsp-win64.zip
for z in "$tmp"/*.zip; do unzip -o -q "$z" -d .; done
fetch globalTypes.d.luau https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau
rm -rf "$tmp"
ls -1
