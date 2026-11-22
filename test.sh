#!/bin/sh
set -eu

cd "$(dirname "$0")"
developer_dir="$(xcode-select -p)"

if [ -d "$developer_dir/Platforms/MacOSX.platform" ]; then
    exec swift test --disable-xctest "$@"
fi

# Command Line Tools ship Testing outside the default framework search path.
toolchain_frameworks="$developer_dir/Library/Developer/Frameworks"
exec swift test --build-system native --disable-xctest \
    -Xswiftc -F -Xswiftc "$toolchain_frameworks" \
    -Xlinker -rpath -Xlinker "$toolchain_frameworks" "$@"
