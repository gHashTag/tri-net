#!/usr/bin/env bash
# A2 Device-DNA smoke — two attest_dna instances on loopback prove that:
#   (1) each responds to a valid challenge with a spec-conformant 98-byte frame
#   (2) responses from different node IDs carry different DNA payloads
#   (3) response fails freshness gate if timestamp is 60s old (replay-guard)
#
# Ratchet reminder: this is SIM-ONLY (-sim). Real DNA_PORT read on P203 Mini
# happens after openXC7 bitstream + board flash + on-device smoke. See
# tri-net-fpga-attestation-workflow skill §Sandbox-vs-hardware discipline.
#
# phi^2 + phi^-2 = 3

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/target/spec-first/attest_dna"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN missing" >&2; exit 1
fi

echo "[smoke] launching two attest_dna instances"
TRINET_NODE=11 ATTEST_DNA_BIND=127.0.0.1:9611 "$BIN" >/tmp/attest_a.log 2>&1 &
A_PID=$!
TRINET_NODE=12 ATTEST_DNA_BIND=127.0.0.1:9612 "$BIN" >/tmp/attest_b.log 2>&1 &
B_PID=$!
trap "kill $A_PID $B_PID 2>/dev/null || true" EXIT
sleep 0.5

pass() { printf "  [PASS] %s\n" "$1"; }
fail() { printf "  [FAIL] %s\n" "$1"; exit 2; }

# Send a challenge and return the response as hex. Uses pure python (no nc).
send_challenge() {
  local port="$1" ts="$2"
  python3 - "$port" "$ts" <<'PY'
import socket, struct, sys, os
port = int(sys.argv[1])
ts   = int(sys.argv[2])
nonce = os.urandom(16)
frame = bytes([0x01]) + nonce + struct.pack('>Q', ts)
assert len(frame) == 25
sock = socket.socket()
sock.settimeout(2.0)
try:
    sock.connect(("127.0.0.1", port))
    sock.sendall(frame)
    data = b""
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
        if len(data) >= 98:
            break
    sys.stdout.write(data.hex())
except socket.timeout:
    pass
finally:
    sock.close()
PY
}

NOW="$(date +%s)"

echo "[smoke] 1/4 node-11 answers a fresh challenge with 98-byte response"
RESP_A="$(send_challenge 9611 "$NOW")"
LEN_A=$(( ${#RESP_A} / 2 ))
echo "  response len bytes: $LEN_A"
[[ "$LEN_A" == "98" ]] || fail "node-11 response len $LEN_A != 98"
# Byte 0 must be MSG_RESPONSE = 0x02
[[ "${RESP_A:0:2}" == "02" ]] || fail "node-11 first byte not 0x02"
pass "node-11 emitted 98-byte MSG_RESPONSE"

echo "[smoke] 2/4 node-12 answers with distinct DNA payload"
RESP_B="$(send_challenge 9612 "$NOW")"
LEN_B=$(( ${#RESP_B} / 2 ))
[[ "$LEN_B" == "98" ]] || fail "node-12 response len $LEN_B != 98"
# DNA payload occupies bytes 25..33 (dna_bits + dna_hi + dna_lo = 9 bytes).
# Hex offsets: 25*2=50, 33*2=66.
DNA_A="${RESP_A:50:18}"
DNA_B="${RESP_B:50:18}"
echo "  DNA node-11: $DNA_A"
echo "  DNA node-12: $DNA_B"
[[ "$DNA_A" != "$DNA_B" ]] || fail "distinct nodes returned identical DNA"
pass "distinct nodes -> distinct sim DNAs"

echo "[smoke] 3/4 stale challenge (60s old) is silently dropped"
OLD=$((NOW - 60))
STALE_OUT="$(send_challenge 9611 "$OLD")"
if [[ -z "$STALE_OUT" ]]; then
  pass "stale challenge dropped (empty response)"
else
  fail "stale challenge accepted: $(echo -n "$STALE_OUT" | head -c 40)"
fi

echo "[smoke] 4/4 replayed valid response from A cannot pass as B"
# The sim signature is deterministic per transcript. Two nodes see two
# different transcripts (different DNA), so a replay of A's response into a
# verifier expecting B would fail signature/DNA binding. We approximate by
# checking that the two responses differ throughout the signature region
# (bytes 34..97).
SIG_A="${RESP_A:68:128}"
SIG_B="${RESP_B:68:128}"
[[ "$SIG_A" != "$SIG_B" ]] || fail "signatures identical across nodes"
pass "signatures diverge across nodes"

echo "[smoke] all 4 checks passed"
