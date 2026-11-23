#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./test.sh
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
xcrun swiftc -swift-version 6 -D HANDOFF_FIXTURE -parse-as-library Core/*.swift Shared/*.swift -o "$stage/fixture"
python3 Tests/CoreLifecycle.py "$stage/fixture"
./build.sh
codesign --verify --deep --strict '.build/Keyboard Handoff.app'
