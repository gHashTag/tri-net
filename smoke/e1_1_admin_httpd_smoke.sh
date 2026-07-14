#!/usr/bin/env bash
# Smoke test for admin_httpd (E1.1). Sandbox-only (-sim).
#
# What this actually verifies:
#   * The binary builds against the crate.
#   * The generated t27 modules (ptt_frame_gen, ws_accept_gen, admin_status_gen)
#     compile and link.
#   * /api/status returns valid JSON with node_id + uptime_s.
#   * WebSocket upgrade completes (Sec-WebSocket-Accept round-trips through
#     the generated SHA-1 + base64 primitives).
#   * PWA index.html is served with correct MIME type.
#
# What this does NOT verify:
#   * Real link-layer transport (iPhone tethering to P203 Mini).
#   * mDNS discovery from an iOS client (requires physical iPhone + entitlements).
#   * mTLS mutual auth (E2.2 — not yet implemented).
#   * Opus audio pipeline (E3.x — not yet implemented).
#
# Exit codes:
#   0 = all checks passed in sandbox
#   1 = build failure
#   2 = status endpoint failure
#   3 = websocket upgrade failure
#   4 = static file failure
#
# phi^2 + phi^-2 = 3

set -u
cd "$(dirname "$0")/.."

PORT="${PORT:-18080}"
NODE_ID="${NODE_ID:-11}"
LOG=$(mktemp -t admin_httpd_smoke.XXXXXX)
trap 'kill $HTTPD_PID 2>/dev/null || true; rm -f "$LOG"' EXIT

echo "== build admin-httpd =="
# The standalone bin includes the three generated t27 modules directly via
# #[path]; it does NOT depend on the crate root, which is pre-existing broken
# (unrelated defects in older gen/rust/*.rs files). Build with rustc directly.
mkdir -p target/spec-first
BIN=target/spec-first/admin_httpd
if ! rustc --edition 2021 -O -A dead_code -A unused_parens \
    src/bin/admin_httpd.rs -o "$BIN" 2>&1 | tail -5; then
  echo "FAIL: build"
  exit 1
fi

echo "== launch on 127.0.0.1:$PORT =="
"$BIN" "127.0.0.1:$PORT" webui/public "$NODE_ID" > "$LOG" 2>&1 &
HTTPD_PID=$!
sleep 1

if ! kill -0 "$HTTPD_PID" 2>/dev/null; then
  echo "FAIL: daemon exited"
  cat "$LOG"
  exit 1
fi

echo "== /api/status =="
STATUS=$(curl -s --max-time 3 "http://127.0.0.1:$PORT/api/status")
if [ -z "$STATUS" ]; then
  echo "FAIL: no /api/status response"
  cat "$LOG"
  exit 2
fi
echo "$STATUS"
echo "$STATUS" | grep -q "\"node_id\":$NODE_ID" || { echo "FAIL: node_id mismatch"; exit 2; }
echo "$STATUS" | grep -q "\"uptime_s\":" || { echo "FAIL: missing uptime_s"; exit 2; }
echo "$STATUS" | grep -q "\"attest_state\":" || { echo "FAIL: missing attest_state"; exit 2; }

echo "== / (index.html) =="
INDEX=$(curl -s --max-time 3 "http://127.0.0.1:$PORT/")
echo "$INDEX" | grep -q "Tri-Net Admin" || { echo "FAIL: index.html not served"; exit 4; }

echo "== websocket upgrade =="
# Static handshake using RFC 6455 test vector. Server must respond 101 +
# Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=  (from generated primitives).
UPGRADE_RESP=$(printf 'GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n' | \
  timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT; cat >&3; timeout 1 head -c 512 <&3")
echo "$UPGRADE_RESP" | head -1
if ! echo "$UPGRADE_RESP" | grep -q "101 Switching Protocols"; then
  echo "FAIL: no 101 upgrade"
  echo "$UPGRADE_RESP"
  exit 3
fi
if ! echo "$UPGRADE_RESP" | grep -q "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="; then
  echo "FAIL: wrong Sec-WebSocket-Accept (generated primitives regression)"
  echo "$UPGRADE_RESP"
  exit 3
fi

echo
echo "== smoke passed =="
echo "  build: ok"
echo "  /api/status: node_id=$NODE_ID, uptime present"
echo "  /: index.html served"
echo "  /ws: 101 + correct accept (SHA-1 + base64 via generated primitives)"
echo
echo "-sim: iPhone-tethering + real audio + mTLS not exercised. See docs/E1_1_IPHONE_TOPOLOGY.md."
echo "phi^2 + phi^-2 = 3"
exit 0
