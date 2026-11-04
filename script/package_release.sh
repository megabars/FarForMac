#!/usr/bin/env bash
set -euo pipefail
export TZ=UTC
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source Resources/Version.env
CONFIGURATION=release "$ROOT_DIR/script/build_and_run.sh" --build-only
ARCH="$(uname -m)"
NAME="FarForMac-$APP_VERSION-$APP_BUILD-$ARCH"
APP="$ROOT_DIR/dist/FarForMac.app"
# ZIP timestamps and entry ordering are fixed. Developer ID timestamp signatures
# intentionally make signed archives differ between builds.
find "$APP" -exec touch -t 202001010000 {} +
rm -f "dist/$NAME.zip"
(cd dist && LC_ALL=C find FarForMac.app -type f | LC_ALL=C sort | TZ=UTC zip -X -q "$NAME.zip" -@)
VERIFY_DIR="$(mktemp -d "$ROOT_DIR/dist/verify.XXXXXX")"
trap 'rm -rf "$VERIFY_DIR"' EXIT
unzip -q "dist/$NAME.zip" -d "$VERIFY_DIR"
"$ROOT_DIR/script/verify_bundle.sh" "$VERIFY_DIR/FarForMac.app"
(cd dist && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
echo "$ROOT_DIR/dist/$NAME.zip"
