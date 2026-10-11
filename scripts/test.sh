#!/usr/bin/env bash
# Runs the test suite. With only the Command Line Tools installed (no Xcode), SwiftPM doesn't
# find the Swift Testing framework by itself, so point the compiler and linker at it.
set -euo pipefail
cd "$(dirname "$0")/.."

developer_dir="$(xcode-select -p)"
flags=()
if [[ "$developer_dir" == *CommandLineTools* ]]; then
  frameworks="$developer_dir/Library/Developer/Frameworks"
  libraries="$developer_dir/Library/Developer/usr/lib"
  flags=(
    -Xswiftc -F -Xswiftc "$frameworks"
    -Xlinker -F -Xlinker "$frameworks"
    -Xlinker -rpath -Xlinker "$frameworks"
    -Xlinker -rpath -Xlinker "$libraries"
  )
fi

swift test ${flags[@]+"${flags[@]}"} "$@"
