#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
case "$MODE" in run|--build-only|--verify|--debug|--logs|--telemetry) ;; *) echo "Usage: $0 [--build-only|--verify|--debug|--logs|--telemetry]"; exit 2 ;; esac
source "$ROOT_DIR/Resources/Version.env"
APP_NAME=FarForMac
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
CONFIGURATION="${CONFIGURATION:-debug}"
case "$CONFIGURATION" in debug|release) ;; *) echo 'CONFIGURATION must be debug or release' >&2; exit 2 ;; esac
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/ModuleCache"
swift build --disable-sandbox --cache-path "$ROOT_DIR/.build/cache" -c "$CONFIGURATION"
BUILD_BINARY="$(swift build --disable-sandbox -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"
# Stage separately: build-only never quits or launches an existing application.
STAGE="$(mktemp -d "$ROOT_DIR/dist-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
BUNDLE="$STAGE/$APP_NAME.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/Extensions" "$STAGE/AppIcon.iconset"
cp "$BUILD_BINARY" "$BUNDLE/Contents/MacOS/$APP_NAME"
swift "$ROOT_DIR/script/render_icon.swift" "$STAGE/AppIcon.iconset"
cp "$STAGE/AppIcon.iconset/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FarForMac</string>
<key>CFBundleIdentifier</key><string>dev.farmac.app</string>
<key>CFBundleName</key><string>FarForMac</string>
<key>CFBundleDisplayName</key><string>FarForMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>$APP_BUILD</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Ivan Mezentsev. All rights reserved.</string>
</dict></plist>
PLIST
cp THIRD_PARTY_NOTICES.md "$BUNDLE/Contents/Resources/"
cp LICENSE "$BUNDLE/Contents/Resources/"
cp Examples/Extensions/text-tools.py "$BUNDLE/Contents/Resources/Extensions/"
chmod 755 "$BUNDLE/Contents/Resources/Extensions/text-tools.py"
if [[ -n "${DEVELOPER_ID_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_IDENTITY" "$BUNDLE"
else
    codesign --force --sign - "$BUNDLE"
fi
"$ROOT_DIR/script/verify_bundle.sh" "$BUNDLE"
mkdir -p "$ROOT_DIR/dist"
rm -rf "$APP_BUNDLE"
mv "$BUNDLE" "$APP_BUNDLE"
case "$MODE" in
    --build-only) echo "$APP_BUNDLE" ;;
    --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
    --logs|--telemetry) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "FarForMac"' ;;
    --verify) open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" ;;
    run) open -n "$APP_BUNDLE" ;;
esac
