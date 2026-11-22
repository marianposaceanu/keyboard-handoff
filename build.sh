#!/bin/sh
set -eu

cd "$(dirname "$0")"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p .build

staging="$(mktemp -d "$PWD/.build/bundle.XXXXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Keyboard Handoff.app"
mkdir -p "$app/Contents/MacOS"

for architecture in arm64 x86_64; do
    xcrun swiftc -swift-version 6 -O -parse-as-library \
        -sdk "$sdk" -target "$architecture-apple-macosx14.0" \
        KeyboardHandoff/*.swift Shared/*.swift -o "$staging/KeyboardHandoff-$architecture"
done

xcrun lipo -create "$staging/KeyboardHandoff-arm64" "$staging/KeyboardHandoff-x86_64" \
    -output "$app/Contents/MacOS/KeyboardHandoff"
TARGET_BUILD_DIR="$app" EXECUTABLE_FOLDER_PATH=Contents/MacOS scripts/build-core.sh
cp Info.plist "$app/Contents/Info.plist"
codesign --sign - "$app"
ditto "$app" ".build/Keyboard Handoff.app"
printf '%s\n' "$PWD/.build/Keyboard Handoff.app"
