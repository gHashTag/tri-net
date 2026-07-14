#!/usr/bin/env bash
# e3_2_replay_smoke.sh — W7 regression gate for weak-point #8 (replay).
#
# Goal: prove that audio_forwarder rejects a re-sent (session_id, seq)
# tuple. Sends 3 valid frames with seq 1,2,3 twice; expects:
#   - first pass:  3 frames_ok, 3 forwarded, reject_replay=0
#   - second pass: 3 frames_ok, 3 forwarded (still), reject_replay=3
# The "still 3 forwarded" is because the second pass never reaches the
# UDP fan-out — replay is rejected before send_to.
#
# phi^2 + phi^-2 = 3

set -euo pipefail

cd "$(dirname "$0")/.."

BIN=target/spec-first/audio_forwarder
if [[ ! -x "$BIN" ]]; then
  echo "[smoke] building audio_forwarder"
  rustc --edition 2021 -O -A dead_code -A unused_parens -A unused-comparisons \
    src/bin/audio_forwarder.rs -o "$BIN"
fi

# Pick free ports.
TCP_PORT=9721
STATS_PORT=9722
UDP_PORT=9731

# Start UDP sink to consume forwarded frames. Sink runs long enough to
# see both send-passes, then times out and writes count to log file.
rm -f /tmp/udp_sink.log
python3 -u -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('127.0.0.1', $UDP_PORT))
s.settimeout(4)
count = 0
try:
  while True:
    s.recvfrom(4096)
    count += 1
except socket.timeout:
  pass
with open('/tmp/udp_sink.log', 'w') as f:
  f.write(f'udp_sink_count={count}\n')
" &
SINK_PID=$!
sleep 0.3

# Start audio_forwarder.
AUDIO_FWD_BIND=127.0.0.1:$TCP_PORT \
AUDIO_FWD_PEERS=127.0.0.1:$UDP_PORT \
AUDIO_FWD_UDP_BIND=127.0.0.1:0 \
AUDIO_FWD_STATS_PORT=$STATS_PORT \
"$BIN" > /tmp/audio_replay.log 2>&1 &
FWD_PID=$!
sleep 0.3

cleanup() {
  kill "$FWD_PID" 2>/dev/null || true
  kill "$SINK_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

# Build a valid frame: version=1, session_id=0xDEADBEEF, seq=$1, opus_len=80.
craft_frame() {
  local seq=$1
  python3 -c "
import sys, struct
seq = int(sys.argv[1])
buf = bytearray()
buf.append(1)
buf += struct.pack('>I', 0xDEADBEEF)
buf += struct.pack('>H', seq)
buf += struct.pack('>H', 80)
buf += bytes([0xF8] * 80)
sys.stdout.buffer.write(bytes(buf))
" "$seq"
}

send_frames() {
  local pass=$1
  {
    craft_frame 1
    craft_frame 2
    craft_frame 3
  } | python3 -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(('127.0.0.1', $TCP_PORT))
data = sys.stdin.buffer.read()
s.sendall(data)
s.close()
"
  sleep 0.2
  echo "[smoke] pass $pass sent 3 frames"
}

read_stats() {
  python3 -c "
import socket
s = socket.socket()
s.connect(('127.0.0.1', $STATS_PORT))
print(s.recv(1024).decode().strip())
"
}

fail=0
pass_count=0

echo "[smoke] 1/4 first pass: 3 fresh frames should all be accepted"
send_frames 1
STATS1=$(read_stats)
echo "  stats after pass1: $STATS1"
if echo "$STATS1" | grep -q "frames_ok=3" && echo "$STATS1" | grep -q "reject_replay=0" && echo "$STATS1" | grep -q "forwarded=3"; then
  echo "  [PASS] 3 accepted, 0 replays, 3 forwarded"
  pass_count=$((pass_count+1))
else
  echo "  [FAIL] unexpected stats: $STATS1"
  fail=1
fi

echo "[smoke] 2/4 second pass: same 3 (session,seq) tuples should be replays"
send_frames 2
STATS2=$(read_stats)
echo "  stats after pass2: $STATS2"
if echo "$STATS2" | grep -q "frames_ok=6" && echo "$STATS2" | grep -q "reject_replay=3"; then
  echo "  [PASS] 6 total accepted (spec-level), 3 rejected as replay"
  pass_count=$((pass_count+1))
else
  echo "  [FAIL] replay counter did not bump: $STATS2"
  fail=1
fi

echo "[smoke] 3/4 forwarded count should still be 3 (replays not fanned out)"
FWD=$(echo "$STATS2" | grep -oE "forwarded=[0-9]+" | head -1 | cut -d= -f2)
if [[ "$FWD" == "3" ]]; then
  echo "  [PASS] forwarded stayed at 3 — replays blocked pre-send_to"
  pass_count=$((pass_count+1))
else
  echo "  [FAIL] forwarded=$FWD (expected 3)"
  fail=1
fi

echo "[smoke] 4/4 UDP sink should have received exactly 3 frames"
# Wait for UDP sink to time out and write its log.
wait "$SINK_PID" 2>/dev/null || true
SINK_COUNT=$(grep -oE "udp_sink_count=[0-9]+" /tmp/udp_sink.log 2>/dev/null | cut -d= -f2)
SINK_COUNT=${SINK_COUNT:-0}
if [[ "$SINK_COUNT" == "3" ]]; then
  echo "  [PASS] UDP sink observed 3 unique frames"
  pass_count=$((pass_count+1))
else
  echo "  [FAIL] UDP sink observed $SINK_COUNT frames (expected 3)"
  fail=1
fi

echo ""
if [[ "$fail" == "0" ]]; then
  echo "[smoke] all 4 checks passed ($pass_count/4)"
  exit 0
else
  echo "[smoke] FAILURES observed ($pass_count/4 passed)"
  exit 2
fi
