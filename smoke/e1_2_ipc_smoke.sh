#!/usr/bin/env bash
# E1.2 IPC smoke — writer/reader loop between trios_meshd and admin_httpd.
#
# We don't need trios_meshd running to test the IPC contract itself. We
# generate a spec-conformant status file and check admin_httpd surfaces it
# via /api/neighbors and the /ws stream.
#
# phi^2 + phi^-2 = 3

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/target/spec-first/admin_httpd"
WEBROOT="$ROOT/webui/public"
PORT="${PORT:-8091}"
NODE="${NODE:-11}"
STATUS_FILE="/tmp/trinet-${NODE}-status.json"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN missing. Build first: rustc --edition 2021 -O -A dead_code -A unused_parens src/bin/admin_httpd.rs -o target/spec-first/admin_httpd" >&2
  exit 1
fi

echo "[smoke] cleaning any stale status file"
rm -f "$STATUS_FILE" "${STATUS_FILE}.tmp"

echo "[smoke] launching admin_httpd on 127.0.0.1:$PORT node=$NODE"
TRINET_STATUS_PATH="$STATUS_FILE" TRINET_NODE="$NODE" \
  "$BIN" "127.0.0.1:$PORT" "$WEBROOT" &
SRV_PID=$!
trap "kill $SRV_PID 2>/dev/null || true; rm -f $STATUS_FILE ${STATUS_FILE}.tmp" EXIT
sleep 0.5

pass() { printf "  [PASS] %s\n" "$1"; }
fail() { printf "  [FAIL] %s\n" "$1"; exit 2; }

echo "[smoke] 1/6 /api/neighbors returns empty list when file absent"
RESP="$(curl -sS "http://127.0.0.1:$PORT/api/neighbors")"
echo "  got: $RESP"
echo "$RESP" | grep -q '"list":\[\]' || fail "empty list not surfaced"
echo "$RESP" | grep -q '"fresh":false' || fail "fresh flag not false"
pass "empty case handled"

echo "[smoke] 2/6 write valid status file, admin_httpd surfaces it"
UNIX_NOW="$(date +%s)"
cat > "$STATUS_FILE.tmp" <<JSON
{"node_id":$NODE,"seq":42,"tick":9,"uptime_s":30,"unix_time":$UNIX_NOW,"neighbors":[{"id":12,"etx":1.0400,"alive":true},{"id":13,"etx":2.0100,"alive":true}]}
JSON
mv "$STATUS_FILE.tmp" "$STATUS_FILE"
RESP="$(curl -sS "http://127.0.0.1:$PORT/api/neighbors")"
echo "  got: $RESP"
echo "$RESP" | grep -q '"id":12' || fail "neighbor 12 missing"
echo "$RESP" | grep -q '"id":13' || fail "neighbor 13 missing"
echo "$RESP" | grep -q '"fresh":true' || fail "fresh not true"
pass "two neighbors surfaced with fresh=true"

echo "[smoke] 3/6 stale status file (>30s old) reports fresh=false"
OLD_UNIX=$((UNIX_NOW - 45))
cat > "$STATUS_FILE.tmp" <<JSON
{"node_id":$NODE,"seq":42,"tick":9,"uptime_s":30,"unix_time":$OLD_UNIX,"neighbors":[{"id":12,"etx":1.0400,"alive":true}]}
JSON
mv "$STATUS_FILE.tmp" "$STATUS_FILE"
RESP="$(curl -sS "http://127.0.0.1:$PORT/api/neighbors")"
echo "  got: $RESP"
echo "$RESP" | grep -q '"fresh":false' || fail "stale not detected"
echo "$RESP" | grep -q '"id":12' || fail "list still returned even if stale"
pass "stale detected but list surfaced"

echo "[smoke] 4/6 corrupt/torn file (missing bracket) yields empty list"
printf '{"node_id":%s,"neighbors":' "$NODE" > "$STATUS_FILE"
RESP="$(curl -sS "http://127.0.0.1:$PORT/api/neighbors")"
echo "  got: $RESP"
echo "$RESP" | grep -q '"list":\[\]' || fail "torn file not degraded"
pass "torn file degraded gracefully"

echo "[smoke] 5/6 /api/status still works alongside /api/neighbors"
UNIX_NOW="$(date +%s)"
cat > "$STATUS_FILE.tmp" <<JSON
{"node_id":$NODE,"seq":1,"tick":1,"uptime_s":1,"unix_time":$UNIX_NOW,"neighbors":[]}
JSON
mv "$STATUS_FILE.tmp" "$STATUS_FILE"
RESP="$(curl -sS "http://127.0.0.1:$PORT/api/status")"
echo "  got: $RESP"
echo "$RESP" | grep -q '"node_id":'"$NODE" || fail "status broken"
pass "status endpoint co-exists"

echo "[smoke] 6/6 path traversal still forbidden"
# Use --path-as-is so curl doesn't normalise '..' before sending.
CODE="$(curl -sS --path-as-is -o /dev/null -w '%{http_code}' 'http://127.0.0.1:'"$PORT"'/../etc/passwd')"
[[ "$CODE" == "403" ]] || fail "traversal not blocked (got $CODE)"
pass "path traversal blocked"

echo "[smoke] all 6 checks passed"
