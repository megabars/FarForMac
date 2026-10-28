#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_NAME="FarForMac"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/ModuleCache"
case "$MODE" in run|--build-only|--verify|--debug|--logs|--telemetry) ;; *) echo "Usage: $0 [--build-only|--verify|--debug|--logs|--telemetry]"; exit 2 ;; esac
# Keep the bundle identifier and stored preference keys across the FarMac rename.
# Ask either process name to quit normally, so unsaved editor buffers can be saved.
if pgrep -x "$APP_NAME" >/dev/null || pgrep -x "FarMac" >/dev/null; then
    osascript -e 'tell application id "dev.farmac.app" to quit'
    if pgrep -x "$APP_NAME" >/dev/null || pgrep -x "FarMac" >/dev/null; then
        echo "FarForMac is still open. Finish the operation or close unsaved documents before rebuilding."
        exit 1
    fi
fi
swift build --disable-sandbox --cache-path "$ROOT_DIR/.build/cache"
BUILD_BINARY="$(swift build --disable-sandbox --show-bin-path)/$APP_NAME"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BUILD_BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FarForMac</string>
<key>CFBundleIdentifier</key><string>dev.farmac.app</string>
<key>CFBundleName</key><string>FarForMac</string>
<key>CFBundleDisplayName</key><string>FarForMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>FarForMac — independent macOS file manager.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP_BUNDLE"
case "$MODE" in
    --build-only) echo "$APP_BUNDLE" ;;
    --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
    --logs|--telemetry)
        open -n "$APP_BUNDLE"
        /usr/bin/log stream --info --style compact --predicate 'process == "FarForMac"'
        ;;
    --verify) open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" ;;
    run) open -n "$APP_BUNDLE" ;;
esac
