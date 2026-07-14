#!/usr/bin/env bash
# E3.2 audio-forward smoke — start audio_forwarder, feed hand-crafted
# audio frame envelopes via TCP, verify stats counters advance and the UDP
# fan-out reaches a listener.
#
# End-to-end path this smoke covers:
#     [PWA WebCodecs Opus] → [admin_httpd WS] → [TCP :9701] → audio_forwarder
#       → [UDP fan-out] → peers
# Here we simulate the middle-onward hop directly with python.
#
# phi^2 + phi^-2 = 3

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/target/spec-first/audio_forwarder"
FWD_PORT="${FWD_PORT:-9701}"
STATS_PORT="${STATS_PORT:-9702}"
PEER_PORT="${PEER_PORT:-9711}"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN missing" >&2; exit 1
fi

pass() { printf "  [PASS] %s\n" "$1"; }
FWD_PID=0
LISTENER_PID=0
fail() { printf "  [FAIL] %s\n" "$1"; [[ $FWD_PID -gt 0 ]] && kill $FWD_PID 2>/dev/null; [[ $LISTENER_PID -gt 0 ]] && kill $LISTENER_PID 2>/dev/null; exit 2; }
cleanup() { [[ $FWD_PID -gt 0 ]] && kill $FWD_PID 2>/dev/null; [[ $LISTENER_PID -gt 0 ]] && kill $LISTENER_PID 2>/dev/null; return 0; }
trap cleanup EXIT

echo "[smoke] launching audio_forwarder on :$FWD_PORT, stats :$STATS_PORT, peer :$PEER_PORT"
AUDIO_FWD_BIND="127.0.0.1:$FWD_PORT" \
AUDIO_FWD_PEERS="127.0.0.1:$PEER_PORT" \
AUDIO_FWD_STATS_PORT="$STATS_PORT" \
  "$BIN" >/tmp/afwd.log 2>&1 &
FWD_PID=$!
sleep 0.5

# UDP listener as a separate python script.
cat >/tmp/udp_listen.py <<PY
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", $PEER_PORT))
s.settimeout(3.5)
count = 0; total = 0
end = time.time() + 3.5
while time.time() < end:
    try:
        data, _ = s.recvfrom(2048)
        count += 1; total += len(data)
    except socket.timeout:
        break
print(f"count={count} bytes={total}")
PY
python3 /tmp/udp_listen.py >/tmp/udp_recv.log 2>&1 &
LISTENER_PID=$!
sleep 0.3

echo "[smoke] 1/5 send 3 valid frames"
python3 - "$FWD_PORT" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket()
s.connect(("127.0.0.1", port))
for seq in range(3):
    opus = bytes([0xF8]) * 80
    frame = bytes([1]) + b"\x00\x00\x00\x00" + seq.to_bytes(2, "big") + len(opus).to_bytes(2, "big") + opus
    s.sendall(frame)
s.close()
PY
sleep 0.5
pass "3 frames sent"

read_stats() {
  python3 - "$STATS_PORT" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket(); s.connect(('127.0.0.1', port))
print(s.recv(1024).decode(), end='')
PY
}

echo "[smoke] 2/5 stats reports frames_in >= 3"
STATS="$(read_stats)"
echo "  stats: $STATS"
IN=$(echo "$STATS" | grep -oE 'frames_in=[0-9]+' | head -1 | cut -d= -f2)
[[ "${IN:-0}" -ge 3 ]] || fail "frames_in < 3 (was ${IN:-0})"
pass "frames_in=${IN}"

echo "[smoke] 3/5 stats reports frames_ok >= 3"
OK=$(echo "$STATS" | grep -oE 'frames_ok=[0-9]+' | head -1 | cut -d= -f2)
[[ "${OK:-0}" -ge 3 ]] || fail "frames_ok < 3 (was ${OK:-0})"
pass "frames_ok=${OK}"

echo "[smoke] 4/5 stats reports forwarded >= 3"
FWD=$(echo "$STATS" | grep -oE 'forwarded=[0-9]+' | head -1 | cut -d= -f2)
[[ "${FWD:-0}" -ge 3 ]] || fail "forwarded < 3 (was ${FWD:-0})"
pass "forwarded=${FWD}"

echo "[smoke] 5/5 send an invalid frame (bad version) — reject_version bumps"
python3 - "$FWD_PORT" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket(); s.connect(("127.0.0.1", port))
opus = bytes([0xF8]) * 40
bad = bytes([2]) + b"\x00\x00\x00\x00" + b"\x00\x00" + len(opus).to_bytes(2, "big") + opus
s.sendall(bad); s.close()
PY
sleep 0.5
STATS2="$(read_stats)"
REJ=$(echo "$STATS2" | grep -oE 'reject_version=[0-9]+' | head -1 | cut -d= -f2)
[[ "${REJ:-0}" -ge 1 ]] || fail "reject_version < 1 (was ${REJ:-0})"
pass "reject_version=${REJ}"

# Wait for UDP listener to time out so we can inspect what it saw.
wait $LISTENER_PID 2>/dev/null || true
echo "[smoke] UDP listener said: $(cat /tmp/udp_recv.log)"
UDP_COUNT=$(grep -oE 'count=[0-9]+' /tmp/udp_recv.log | head -1 | cut -d= -f2)
[[ "${UDP_COUNT:-0}" -ge 3 ]] || fail "UDP listener received < 3 frames (got ${UDP_COUNT:-0})"

echo "[smoke] all 6 checks passed"
