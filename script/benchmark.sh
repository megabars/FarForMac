#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
# Build outside the measured process; forward --smoke to reduce CI fixture cost.
swift build --disable-sandbox --cache-path "$PWD/.build/cache" -c release -debug-info-format none --product FarPerformance >&2
BIN_DIR="$(swift build --disable-sandbox --cache-path "$PWD/.build/cache" -c release -debug-info-format none --show-bin-path)"
exec "$BIN_DIR/FarPerformance" "$@"
