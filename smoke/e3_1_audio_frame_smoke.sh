#!/usr/bin/env bash
# E3.1 audio-frame envelope smoke — WebSocket client sends valid + malformed
# frames, admin_httpd emits the expected verdicts.
#
# Verdicts come from the spec predicates in specs/ptt_audio.t27. This smoke
# does NOT encode Opus (E3.2). It uses opaque bytes as opus payload.
#
# phi^2 + phi^-2 = 3

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/target/spec-first/admin_httpd"
WEBROOT="$ROOT/webui/public"
PORT="${PORT:-8092}"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN missing" >&2; exit 1
fi

echo "[smoke] launching admin_httpd on 127.0.0.1:$PORT"
"$BIN" "127.0.0.1:$PORT" "$WEBROOT" >/tmp/adm_e3.log 2>&1 &
SRV_PID=$!
trap "kill $SRV_PID 2>/dev/null || true" EXIT
sleep 0.5

pass() { printf "  [PASS] %s\n" "$1"; }
fail() { printf "  [FAIL] %s\n" "$1"; kill $SRV_PID 2>/dev/null; exit 2; }

run_ws_case() {
  local label="$1" opus_hex="$2" tamper="$3" expect="$4"
  python3 - "$PORT" "$opus_hex" "$tamper" <<'PY'
import base64, hashlib, os, socket, struct, sys, json

port = int(sys.argv[1]); opus_hex = sys.argv[2]; tamper = sys.argv[3]
opus = bytes.fromhex(opus_hex) if opus_hex else b""

def ws_client(port):
    s = socket.socket()
    s.settimeout(3.0)
    s.connect(("127.0.0.1", port))
    key = base64.b64encode(os.urandom(16)).decode()
    hs = (
        f"GET /ws HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n\r\n"
    ).encode()
    s.sendall(hs)
    # Consume the entire handshake response by reading until CRLFCRLF.
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk: break
        buf += chunk
    return s

def ws_send_text(sock, text):
    payload = text.encode()
    hdr = bytes([0x81])
    mask = os.urandom(4)
    if len(payload) < 126:
        hdr += bytes([0x80 | len(payload)])
    elif len(payload) < 65536:
        hdr += bytes([0x80 | 126]) + struct.pack('>H', len(payload))
    else:
        hdr += bytes([0x80 | 127]) + struct.pack('>Q', len(payload))
    hdr += mask
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(hdr + masked)

def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return buf
        buf += chunk
    return buf

def ws_recv_text(sock, expect_type):
    # Skip frames until we find one with expect_type. Time-bounded.
    import time
    end = time.time() + 3.0
    while time.time() < end:
        h = recv_exact(sock, 2)
        if len(h) < 2: return None
        b0, b1 = h[0], h[1]
        length = b1 & 0x7F
        if length == 126:
            length = struct.unpack('>H', recv_exact(sock, 2))[0]
        elif length == 127:
            length = struct.unpack('>Q', recv_exact(sock, 8))[0]
        data = recv_exact(sock, length)
        try:
            txt = data.decode()
        except UnicodeDecodeError:
            continue
        if f'"type":"{expect_type}"' in txt:
            return txt
    return None

# Build envelope: v1 | sid | seq | opus_len | opus
sid = 0xDEADBEEF; seq = 7
frame = bytes([1]) + struct.pack('>I', sid) + struct.pack('>H', seq) + struct.pack('>H', len(opus)) + opus
if tamper == "bad_version":
    frame = bytes([2]) + frame[1:]
elif tamper == "size_mismatch":
    frame = frame + b"\x00"  # extra byte breaks consistency
elif tamper == "short_opus":
    # override opus_len to 2 (below OPUS_MIN_LEN)
    frame = bytes([1]) + struct.pack('>I', sid) + struct.pack('>H', seq) + struct.pack('>H', 2) + b"\x00\x00"

payload_b64 = base64.b64encode(frame).decode()
sock = ws_client(port)
ws_send_text(sock, json.dumps({"type": "audio", "payload": payload_b64}))
ack = ws_recv_text(sock, "audio-ack")
sock.close()
print(ack or "NO ACK")
PY
}

OPUS_80="$(python3 -c "print('F8'*80)")"

echo "[smoke] 1/4 valid v1 frame with 80B opus"
ACK="$(run_ws_case v1_ok "$OPUS_80" none accept)"
echo "  ack: $ACK"
echo "$ACK" | grep -q '"accepted":true' || fail "valid frame rejected"
pass "valid frame accepted"

echo "[smoke] 2/4 bad version"
ACK="$(run_ws_case bad_ver "$OPUS_80" bad_version reject)"
echo "  ack: $ACK"
echo "$ACK" | grep -q '"reason":"bad version"' || fail "bad version not caught"
pass "bad version rejected"

echo "[smoke] 3/4 size mismatch (extra byte)"
ACK="$(run_ws_case mismatch "$OPUS_80" size_mismatch reject)"
echo "  ack: $ACK"
echo "$ACK" | grep -q '"reason":"size mismatch"' || fail "size mismatch not caught"
pass "size mismatch rejected"

echo "[smoke] 4/4 opus_len 2 (below OPUS_MIN_LEN)"
ACK="$(run_ws_case short_opus "" short_opus reject)"
echo "  ack: $ACK"
echo "$ACK" | grep -q '"reason":"opus_len out of bounds"' || fail "under-min not caught"
pass "opus_len 2 rejected"

echo "[smoke] all 4 checks passed"
