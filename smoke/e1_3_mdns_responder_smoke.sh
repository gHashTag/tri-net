#!/usr/bin/env bash
# E1.3 mDNS responder smoke — python client crafts a PTR query for
# _trinet-admin._tcp.local, unicast-sends to 127.0.0.1:5353, checks that
# the response is a well-formed mDNS answer with the expected records.
#
# We use a non-privileged port (5354) since 5353 requires root-friendly
# multicast setup, and the responder honours MDNS_BIND for exactly this
# reason. Multicast join failures are non-fatal in the responder.
#
# phi^2 + phi^-2 = 3

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/target/spec-first/mdns_responder"
PORT="${PORT:-5354}"
NODE="${NODE:-11}"
ADMIN_IP="${ADMIN_IP:-10.0.0.11}"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN missing" >&2; exit 1
fi

echo "[smoke] launching mdns_responder on 127.0.0.1:$PORT node=$NODE"
TRINET_NODE="$NODE" MDNS_BIND="127.0.0.1:$PORT" MDNS_ADMIN_ADDR="$ADMIN_IP" \
  "$BIN" >/tmp/mdns.log 2>&1 &
SRV_PID=$!
trap "kill $SRV_PID 2>/dev/null || true" EXIT
sleep 0.4

pass() { printf "  [PASS] %s\n" "$1"; }
fail() { printf "  [FAIL] %s\n" "$1"; kill $SRV_PID 2>/dev/null; exit 2; }

query_and_recv() {
  local qname="$1" qtype="$2"
  python3 - "$PORT" "$qname" "$qtype" <<'PY'
import socket, struct, sys, time
port  = int(sys.argv[1])
qname = sys.argv[2]
qtype = int(sys.argv[3])

def encode_name(name):
    out = b""
    for lbl in name.split("."):
        if not lbl: continue
        out += bytes([len(lbl)]) + lbl.encode()
    return out + b"\x00"

# Craft query: txid=0xBEEF, flags=0, qd=1, an=ns=ar=0, question(name, qtype, IN)
pkt = struct.pack(">HHHHHH", 0xBEEF, 0, 1, 0, 0, 0)
pkt += encode_name(qname) + struct.pack(">HH", qtype, 1)

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2.0)
s.bind(("127.0.0.1", 0))
s.sendto(pkt, ("127.0.0.1", port))
try:
    data, _src = s.recvfrom(4096)
    sys.stdout.write(data.hex())
except socket.timeout:
    pass
PY
}

echo "[smoke] 1/5 query _trinet-admin._tcp.local PTR yields a reply"
HEX="$(query_and_recv "_trinet-admin._tcp.local" 12)"
[[ -n "$HEX" ]] || fail "no reply to PTR query"
LEN=$(( ${#HEX} / 2 ))
echo "  reply bytes: $LEN"
[[ "$LEN" -ge 60 ]] || fail "reply too short ($LEN bytes)"
pass "PTR reply received ($LEN bytes)"

echo "[smoke] 2/5 reply preserves txid 0xBEEF"
[[ "${HEX:0:4}" == "beef" ]] || fail "txid not preserved: ${HEX:0:4}"
pass "txid preserved"

echo "[smoke] 3/5 flags == FLAGS_ANNOUNCE (0x8400) with QR|AA bits set"
[[ "${HEX:4:4}" == "8400" ]] || fail "flags != 8400: ${HEX:4:4}"
pass "FLAGS_ANNOUNCE set"

echo "[smoke] 4/5 an-count == 4 (PTR+SRV+TXT+A)"
AN_HEX="${HEX:12:4}"
[[ "$AN_HEX" == "0004" ]] || fail "an-count != 4: $AN_HEX"
pass "an-count is 4"

echo "[smoke] 5/5 admin-IP octets embedded in reply (A-record rdata)"
# hex for 10.0.0.11 = 0a00000b
grep -q "0a00000b" <<<"$HEX" || fail "admin ip octets not present"
pass "A-record encodes admin IP"

echo "[smoke] bonus: foreign service should not get a reply"
HEX2="$(query_and_recv "_printer._tcp.local" 12)"
if [[ -z "$HEX2" ]]; then
  pass "foreign service ignored"
else
  fail "foreign service replied unexpectedly"
fi

echo "[smoke] all 6 checks passed"
