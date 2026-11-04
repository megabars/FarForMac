#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/ModuleCache"
SWIFT_VERSION_INFO="$(xcrun swift --version)"
SWIFT_MAJOR="$(awk '/Swift version/ { for (i=1; i<=NF; i++) if ($i == "version") { split($(i+1), v, "."); print v[1]; exit } }' <<< "$SWIFT_VERSION_INFO")"
if [[ ! "$SWIFT_MAJOR" =~ ^[0-9]+$ ]] || (( SWIFT_MAJOR < 6 )); then
    echo "FarForMac tests require Swift 6+. Select Xcode 16+ with DEVELOPER_DIR or xcode-select." >&2
    echo "$SWIFT_VERSION_INFO" >&2
    exit 2
fi
# Some CLT Swift build plans omit discovery of the bundled Testing macros after
# an executable-only build. Load the active toolchain's plugin when available.
SWIFT_TOOLCHAIN_USR="$(dirname "$(dirname "$(xcrun --find swift)")")"
TESTING_PLUGIN="$SWIFT_TOOLCHAIN_USR/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$TESTING_PLUGIN" ]; then
    set -- -Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN" "$@"
fi
xcrun swift test --disable-sandbox --cache-path "$ROOT_DIR/.build/cache" --disable-xctest "$@"
