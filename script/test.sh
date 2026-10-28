#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/ModuleCache"
# Some CLT Swift build plans omit discovery of the bundled Testing macros after
# an executable-only build. Load the active toolchain's plugin when available.
SWIFT_TOOLCHAIN_USR="$(dirname "$(dirname "$(xcrun --find swift)")")"
TESTING_PLUGIN="$SWIFT_TOOLCHAIN_USR/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$TESTING_PLUGIN" ]; then
    set -- -Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN" "$@"
fi
swift test --disable-sandbox --cache-path "$ROOT_DIR/.build/cache" --disable-xctest "$@"
