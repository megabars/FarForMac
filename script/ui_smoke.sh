#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT_DIR/dist/FarForMac.app}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
REPORT="$ROOT_DIR/dist/ui-smoke.json"
mkdir -p "$ROOT_DIR/dist"
rm -f "$REPORT"
# App-owned fixtures and in-process keyboard events; never use user defaults.
SMOKE_CWD="$(mktemp -d "${TMPDIR:-/tmp}/FarForMac-ui-cwd.XXXXXX")"
touch "$SMOKE_CWD/.smoke-owned"
# Never run test helper commands or relative paths from the repository checkout.
(cd "$SMOKE_CWD" && exec "$APP/Contents/MacOS/FarForMac" --ui-smoke-report "$REPORT") &
PID=$!
cleanup() {
    if kill -0 "$PID" 2>/dev/null; then kill "$PID" 2>/dev/null || true; fi
    rm -rf "$SMOKE_CWD"
}
trap cleanup EXIT
for ((i=0; i<30; i++)); do
    if ! kill -0 "$PID" 2>/dev/null; then break; fi
    sleep 1
done
if kill -0 "$PID" 2>/dev/null; then echo 'UI smoke timed out after 30 seconds' >&2; exit 1; fi
EXIT_STATUS=0
wait "$PID" || EXIT_STATUS=$?
if [[ ! -f "$SMOKE_CWD/.smoke-owned" ]]; then
    echo 'UI smoke unexpectedly removed its working directory or ownership marker' >&2
    EXIT_STATUS=1
fi
if (( EXIT_STATUS != 0 )); then
    if [[ -s "$REPORT" ]]; then cat "$REPORT"; fi
    exit "$EXIT_STATUS"
fi
test -s "$REPORT"
STATUS="$(plutil -extract status raw -o - "$REPORT")"
[[ "$STATUS" == passed ]] || { cat "$REPORT"; exit 1; }
cat "$REPORT"
