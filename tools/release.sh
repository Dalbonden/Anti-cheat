#!/usr/bin/env bash
# Release builds for the canary and stable channels (see RELEASING.md).
#
#   tools/release.sh canary   tag v<VERSION>-rc.<N> and build release artifacts
#   tools/release.sh stable   tag v<VERSION>; only for a commit already released as a canary
#
# Requires a clean working tree, a passing tools/verify.sh and a CHANGELOG entry for
# VERSION. Stamps the channel and release version into a staged copy of src/ (the
# repository itself always says "development"), then builds:
#   build/release/ACF-<release>.rbxl   place with ACF installed
#   build/release/ACF-<release>.rbxm   model: drag its folders into the matching services
#   build/release/ACF-<release>.json   manifest (version, channel, commit, tests, checksums)
# Tags are created locally; push them with: git push origin <tag>
set -euo pipefail
cd "$(dirname "$0")/.."

channel="${1:-}"
if [[ "$channel" != "canary" && "$channel" != "stable" ]]; then
	echo "usage: tools/release.sh canary|stable" >&2
	exit 2
fi

if [[ -n "$(git status --porcelain)" ]]; then
	echo "release: working tree is not clean; commit or stash first" >&2
	exit 1
fi

version="$(grep -o 'VERSION = "[^"]*"' src/Shared/Constants.luau | cut -d'"' -f2)"
if ! grep -q "^## \[$version\]" CHANGELOG.md; then
	echo "release: CHANGELOG.md has no '## [$version]' entry" >&2
	exit 1
fi

commit="$(git rev-parse HEAD)"
if [[ "$channel" == "canary" ]]; then
	count="$(git tag --list "v$version-rc.*" | wc -l | tr -d ' ')"
	release="$version-rc.$((count + 1))"
else
	if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
		echo "release: v$version already exists" >&2
		exit 1
	fi
	if ! git tag --points-at HEAD | grep -q "^v$version-rc\."; then
		echo "release: stable must be a commit already released as a canary (v$version-rc.N on HEAD)" >&2
		exit 1
	fi
	release="$version"
fi
tag="v$release"

verify_log="$(mktemp)"
./tools/verify.sh | tee "$verify_log"
tests="$(grep -o '[0-9]*/[0-9]* passed' "$verify_log" | tail -1)"
rm -f "$verify_log"

stage="build/release/stage-$release"
rm -rf "$stage"
mkdir -p "$stage"
cp -r src "$stage/src"
sed -i "s/VERSION = \"[^\"]*\"/VERSION = \"$release\"/; s/CHANNEL = \"[^\"]*\"/CHANNEL = \"$channel\"/" "$stage/src/Shared/Constants.luau"
cp default.project.json "$stage/place.project.json"
cat >"$stage/model.project.json" <<JSON
{
  "name": "ACF-$release",
  "tree": {
    "\$className": "Folder",
    "ServerScriptService": { "\$className": "Folder", "ACF": { "\$path": "src/Server" } },
    "ReplicatedStorage": { "\$className": "Folder", "ACFShared": { "\$path": "src/Shared" } },
    "StarterPlayerScripts": { "\$className": "Folder", "ACFTelemetry": { "\$path": "src/Client/ClientTelemetry.client.luau" } }
  }
}
JSON

out="build/release/ACF-$release"
./.bin/rojo.exe build "$stage/place.project.json" -o "$out.rbxl"
./.bin/rojo.exe build "$stage/model.project.json" -o "$out.rbxm"
place_sha="$(sha256sum "$out.rbxl" | cut -d' ' -f1)"
model_sha="$(sha256sum "$out.rbxm" | cut -d' ' -f1)"
cat >"$out.json" <<JSON
{
  "version": "$release",
  "channel": "$channel",
  "commit": "$commit",
  "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "tests": "$tests",
  "place": { "file": "ACF-$release.rbxl", "sha256": "$place_sha" },
  "model": { "file": "ACF-$release.rbxm", "sha256": "$model_sha" }
}
JSON
rm -rf "$stage"

git tag -a "$tag" -m "ACF $release ($channel)"
echo "released $release ($channel): $out.rbxl, $out.rbxm, $out.json"
echo "tag $tag created locally; push with: git push origin $tag"
