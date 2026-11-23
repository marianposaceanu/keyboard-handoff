#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(plutil -extract CFBundleShortVersionString raw Info.plist)"
tag="${1:?supply a vX.Y.Z release tag}"
[[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ && "$tag" == "v$version" ]]
test "$(git rev-parse "$tag^{commit}")" = "$(git rev-parse HEAD)"
./build.sh
app='.build/Keyboard Handoff.app'
codesign --verify --deep --strict "$app"
mkdir -p "dist/$tag"
archive="Keyboard-Handoff-$tag.zip"
ditto -c -k --keepParent "$app" "dist/$tag/$archive"
(cd "dist/$tag" && shasum -a 256 "$archive" > SHA256SUMS.txt)
