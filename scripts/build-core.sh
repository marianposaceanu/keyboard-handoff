#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}/keyboard-handoff-core"
mkdir -p "$(dirname "$output")"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp Info.plist "$stage/core.plist"
plutil -replace CFBundleIdentifier -string local.keyboard-handoff.core "$stage/core.plist"
plutil -replace CFBundleExecutable -string keyboard-handoff-core "$stage/core.plist"
for arch in ${ARCHS:-arm64 x86_64}; do
    xcrun swiftc -swift-version 6 -Osize -whole-module-optimization -parse-as-library \
        -target "$arch-apple-macosx14.0" Core/*.swift Shared/*.swift \
        -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$stage/core.plist" -o "$stage/core-$arch"
done
xcrun lipo -create "$stage"/core-* -output "$output"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$output"
