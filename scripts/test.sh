#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
bash scripts/prepare-vlc.sh
DEVELOPER_PATH="$(xcode-select -p)"
if [[ "$DEVELOPER_PATH" == *CommandLineTools* ]]; then
    FRAMEWORKS="$DEVELOPER_PATH/Library/Developer/Frameworks"
    swift test --scratch-path .test-build --disable-xctest \
      -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
      -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
      -Xlinker -F -Xlinker "$FRAMEWORKS" \
      -Xlinker -rpath -Xlinker "$FRAMEWORKS"
else
    swift test --disable-xctest
fi
