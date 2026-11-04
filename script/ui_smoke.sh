#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT_DIR/dist/FarForMac.app}"
REPORT="$ROOT_DIR/dist/ui-smoke.json"
mkdir -p "$ROOT_DIR/dist"
rm -f "$REPORT"
# App-internal diagnostics: no synthetic keyboard/mouse input or user defaults.
"$APP/Contents/MacOS/FarForMac" --ui-smoke-report "$REPORT" &
PID=$!
cleanup() { if kill -0 "$PID" 2>/dev/null; then kill "$PID" 2>/dev/null || true; fi; }
trap cleanup EXIT
for ((i=0; i<30; i++)); do
    if ! kill -0 "$PID" 2>/dev/null; then break; fi
    sleep 1
done
if kill -0 "$PID" 2>/dev/null; then echo 'UI smoke timed out after 30 seconds' >&2; exit 1; fi
wait "$PID"
test -s "$REPORT"
STATUS="$(plutil -extract status raw -o - "$REPORT")"
[[ "$STATUS" == passed ]] || { cat "$REPORT"; exit 1; }
cat "$REPORT"
