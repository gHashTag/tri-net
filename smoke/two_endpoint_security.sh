#!/usr/bin/env bash
# two_endpoint_security.sh — verify the identity/pinning security over REAL processes on
# the two-endpoint rig. Single-process loopback can't test this: it self-pairs (safety
# number over one identity, degenerate) and can't stage a MITM. Here each instance gets a
# DISTINCT identity + pin store via TRINET_KC_ACCOUNT / TRINET_PINS_KEY.
#
#   Test 1  two honest peers (A,B) derive the SAME safety number, no false MITM.
#   Test 2  A pins B, then an impostor M (different identity) answers at B's address ->
#           A flags a MITM and refuses the session (no media from M).
set -u
APP=/Applications/TriNetMonitor.app
clean() { for s in "$@"; do
  security delete-generic-password -s com.trinet.identity -a "device-ed25519-$s" >/dev/null 2>&1
  defaults delete com.trinet.monitor "trinetPeerPins-$s" >/dev/null 2>&1
done; }
launch() { # log listen autocall kc pins [extra-env...]
  open -n --env TRINET_LOG="$1" --env TRINET_LISTEN="$2" --env TRINET_AUTOCALL="$3" \
          --env TRINET_KC_ACCOUNT="$4" --env TRINET_PINS_KEY="$5" "$APP"; }
wait_s() { local e=$(( $(date +%s) + $1 )); while [ "$(date +%s)" -lt "$e" ]; do sleep 3; done; }
kill_all() { pkill -9 -f "TriNetMonitor.app/Contents/MacOS" 2>/dev/null; sleep 2; }

kill_all; defaults delete com.trinet.monitor trinetRoom 2>/dev/null; clean A B M; rm -f /tmp/rig[ABM].log
fail=0

echo "== TEST 1: two honest peers derive the SAME safety number =="
launch /tmp/rigA.log 8000 127.0.0.1:8100 A A; sleep 1
launch /tmp/rigB.log 8100 127.0.0.1:8000 B B
wait_s 18; kill_all
SNA=$(grep -aoE "safety number [0-9]+" /tmp/rigA.log 2>/dev/null | tail -1 | grep -oE "[0-9]+")
SNB=$(grep -aoE "safety number [0-9]+" /tmp/rigB.log 2>/dev/null | tail -1 | grep -oE "[0-9]+")
echo "  A=$SNA  B=$SNB"
if [ -n "${SNA:-}" ] && [ "$SNA" = "${SNB:-}" ]; then echo "  PASS (match)"; else echo "  FAIL"; fail=1; fi
if [ "$(grep -aic MITM /tmp/rigA.log)" = 0 ] && [ "$(grep -aic MITM /tmp/rigB.log)" = 0 ]; then
  echo "  PASS (no false MITM)"; else echo "  FAIL (false MITM)"; fail=1; fi

echo "== TEST 2: an impostor identity at the pinned peer is flagged as MITM =="
# A keeps its pin of B from Test 1; M is a fresh distinct identity at B's port.
clean M; rm -f /tmp/rigA.log /tmp/rigM.log
launch /tmp/rigA.log 8000 127.0.0.1:8100 A A; sleep 1
launch /tmp/rigM.log 8100 127.0.0.1:8000 M M
wait_s 16; kill_all
MITM=$(grep -aic MITM /tmp/rigA.log 2>/dev/null); VID=$(grep -aic "FIRST FRAME DECODED" /tmp/rigA.log 2>/dev/null)
echo "  A MITM-flagged=$MITM  video-from-M=$VID"
if [ "${MITM:-0}" -ge 1 ] && [ "${VID:-0}" = 0 ]; then echo "  PASS (detected + refused)"; else echo "  FAIL"; fail=1; fi

clean A B M
echo; [ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURE(S)"
exit $fail
