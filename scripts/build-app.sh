#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
TARGET="${1:-$(uname -m)}"
case "$TARGET" in
    arm64) ARCHES=(arm64); LABEL=AppleSilicon ;;
    x86_64|intel) ARCHES=(x86_64); LABEL=Intel ;;
    --universal|universal) ARCHES=(arm64 x86_64); LABEL=Universal ;;
    *) echo "Usage: build-app.sh [arm64|intel|--universal]" >&2; exit 1 ;;
esac
bash scripts/prepare-dependencies.sh
BINS=()
for ARCH in "${ARCHES[@]}"; do
    swift build -c release --arch "$ARCH"
    BINS+=("$(swift build -c release --arch "$ARCH" --show-bin-path)/TVBoxMac")
done
APP_DIR="$PROJECT_DIR/dist/Release/TVBox.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Helpers" "$APP_DIR/Contents/Frameworks"
for ARCH in "${ARCHES[@]}"; do bash "$PROJECT_DIR/scripts/build-remux.sh" "$ARCH"; done
HELPERS=()
for ARCH in "${ARCHES[@]}"; do HELPERS+=("$PROJECT_DIR/.build/remux-$ARCH/tvbox-remux"); done
lipo -create "${HELPERS[@]}" -output "$APP_DIR/Contents/Helpers/tvbox-remux"
cp "$PROJECT_DIR/.build/remux-${ARCHES[0]}/COPYING.LGPLv2.1" "$APP_DIR/Contents/Resources/FFmpeg-LICENSE.txt"
cp "$PROJECT_DIR/Resources/VLCKit-LICENSE.txt" "$APP_DIR/Contents/Resources/VLCKit-LICENSE.txt"
cp "$PROJECT_DIR/Sources/MPVBridge/MPV-API-LICENSE.txt" "$APP_DIR/Contents/Resources/MPV-API-LICENSE.txt"
cp "$PROJECT_DIR/ThirdPartySources/README.md" "$APP_DIR/Contents/Resources/ThirdParty-Notices.md"
cp "$PROJECT_DIR/ThirdPartySources/CSP-Runtime.md" "$APP_DIR/Contents/Resources/CSP-Runtime.md"
if [[ -f "$PROJECT_DIR/Vendor/CSPRuntime/manifest.json" ]]; then
    ditto "$PROJECT_DIR/Vendor/CSPRuntime" "$APP_DIR/Contents/Resources/CSPRuntime"
else
    echo "CSP runtime is missing. Run python3 scripts/prepare-csp-runtime.py before building the full application." >&2
    exit 1
fi
ditto "$PROJECT_DIR/Vendor/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework" "$APP_DIR/Contents/Frameworks/VLCKit.framework"
ditto "$PROJECT_DIR/Vendor/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
lipo -create "${BINS[@]}" -output "$APP_DIR/Contents/MacOS/TVBoxMac"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
for LANGUAGE in en zh-Hans; do
    ditto "$PROJECT_DIR/Resources/$LANGUAGE.lproj" "$APP_DIR/Contents/Resources/$LANGUAGE.lproj"
done
UPDATE_ARCH="${ARCHES[0]}"
if [[ "${#ARCHES[@]}" -gt 1 ]]; then UPDATE_ARCH=universal; fi
python3 "$PROJECT_DIR/scripts/configure-update-feed.py" "$APP_DIR/Contents/Info.plist" --arch "$UPDATE_ARCH"
swift "$PROJECT_DIR/scripts/make-icon.swift" "$PROJECT_DIR/dist"
iconutil -c icns "$PROJECT_DIR/dist/TVBox.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
python3 "$PROJECT_DIR/scripts/sign-and-check-app.py" "$APP_DIR" "${ARCHES[@]}"
ditto -c -k --keepParent "$APP_DIR" "$PROJECT_DIR/dist/TVBox-macOS-$LABEL.zip"
echo "$LABEL App: $APP_DIR"
