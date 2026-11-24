#!/bin/bash
# Runs the test suite. Works with full Xcode or with only the Command Line Tools installed.
# Usage: Scripts/test.sh [swift test arguments…]
#        Scripts/test.sh --build-only     compile the tests without running them
set -euo pipefail
cd "$(dirname "$0")/.."

FLAGS=()
DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEVELOPER_DIR_PATH" == *CommandLineTools* ]]; then
  # The Command Line Tools ship Swift Testing but do not put it on the default search paths.
  FRAMEWORKS="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
  LIBS="$DEVELOPER_DIR_PATH/Library/Developer/usr/lib"
  PLUGINS="$DEVELOPER_DIR_PATH/usr/lib/swift/host/plugins/testing"
  FLAGS=(-Xswiftc "-F$FRAMEWORKS" -Xswiftc -plugin-path -Xswiftc "$PLUGINS"
         -Xlinker "-F$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$LIBS")
fi

if [ "${1:-}" = "--build-only" ]; then
  exec swift build --build-tests ${FLAGS[@]+"${FLAGS[@]}"}
fi
exec swift test ${FLAGS[@]+"${FLAGS[@]}"} "$@"
