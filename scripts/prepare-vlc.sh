#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$PROJECT_DIR/scripts/fetch-dependencies.py"
ARCHIVE="$PROJECT_DIR/ThirdPartySources/VLCKit-3.7.3.tar.xz"
DEST="$PROJECT_DIR/Vendor/VLCKit.xcframework"
if [[ -f "$DEST/macos-arm64_x86_64/VLCKit.framework/VLCKit" ]]; then exit 0; fi
mkdir -p "$PROJECT_DIR/.build/vlc-extract" "$PROJECT_DIR/Vendor"
tar -xJf "$ARCHIVE" -C "$PROJECT_DIR/.build/vlc-extract" \
    "VLCKit - binary package/COPYING.txt" \
    "VLCKit - binary package/VLCKit.xcframework/Info.plist" \
    "VLCKit - binary package/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework"
ditto "$PROJECT_DIR/.build/vlc-extract/VLCKit - binary package/VLCKit.xcframework" "$DEST"
cp "$PROJECT_DIR/.build/vlc-extract/VLCKit - binary package/COPYING.txt" "$PROJECT_DIR/Resources/VLCKit-LICENSE.txt"
lipo "$DEST/macos-arm64_x86_64/VLCKit.framework/VLCKit" -verify_arch arm64 x86_64
echo "Prepared bundled VLCKit (arm64 + x86_64)"
