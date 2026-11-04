#!/usr/bin/env bash
set -euo pipefail
BUNDLE="${1:?Usage: verify_bundle.sh path/to/FarForMac.app}"
plutil -lint "$BUNDLE/Contents/Info.plist"
for file in MacOS/FarForMac Resources/AppIcon.icns Resources/LICENSE Resources/THIRD_PARTY_NOTICES.md Resources/Extensions/text-tools.py; do
    test -s "$BUNDLE/Contents/$file" || { echo "Missing bundle file: $file" >&2; exit 1; }
done
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$BUNDLE/Contents/Info.plist")"
grep -Fqx "Covered application version: $VERSION" "$BUNDLE/Contents/Resources/LICENSE" || {
    echo "License does not cover application version $VERSION" >&2; exit 1;
}
test -x "$BUNDLE/Contents/MacOS/FarForMac"
codesign --verify --deep --strict --verbose=2 "$BUNDLE"
file "$BUNDLE/Contents/MacOS/FarForMac"
