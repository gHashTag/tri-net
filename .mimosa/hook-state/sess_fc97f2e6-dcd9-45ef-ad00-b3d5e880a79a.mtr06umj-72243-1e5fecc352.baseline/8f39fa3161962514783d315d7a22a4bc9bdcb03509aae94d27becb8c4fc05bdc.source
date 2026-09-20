#!/usr/bin/env bash
# rendezvous_call.sh — two TriNetMonitor instances DISCOVER each other through a blind rendezvous
# (knowing only a shared room passphrase, no hard-coded peer IP) and place a real video call on the
# pair a connectivity check punched. This exercises the WHOLE NAT chain inside the shipping app:
# gather (STUN) -> seal (CandidateOffer) -> publish/fetch (Rendezvous) -> open -> Ice.connect ->
# media. One machine / loopback, so it proves the integrated chain end-to-end but NOT traversal of a
# real NAT (that needs two separate NATs). The relay is the reference rendezvous_serverd.
#
# Usage:  smoke/rendezvous_call.sh [seconds]
set -u
SECS="${1:-40}"
APP=phone/desktop/.dd/Build/Products/Release/TriNetMonitor.app
RZ_PORT=9500
ROOM="rig-room-$$"
A=/tmp/rzA.log; B=/tmp/rzB.log; SRV=/tmp/rzsrv.log
pkill -9 -f "TriNetMonitor.app/Contents/MacOS" 2>/dev/null; sleep 1
rm -f "$A" "$B" "$SRV"

# Two instances on ONE machine share the keychain identity + TOFU pin store by default, so each
# sees the other's handshake at 127.0.0.1 as an "identity change" and the security layer REFUSES
# the session (no media decodes). Give each a DISTINCT identity + pin store and clean them, exactly
# as smoke/two_endpoint_security.sh does — this is a rig artifact, not a call bug.
clean() { for s in "$@"; do
  security delete-generic-password -s com.trinet.identity -a "device-ed25519-$s" >/dev/null 2>&1
  defaults delete com.trinet.monitor "trinetPeerPins-$s" >/dev/null 2>&1
done; }
clean rzA rzB

echo "building + launching the rendezvous relay on :$RZ_PORT ..."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cp smoke/rendezvous_serverd.swift "$TMP/main.swift"   # top-level code must live in main.swift for a multi-file build
if ! swiftc phone/desktop/TriNetVideo/Rendezvous.swift "$TMP/main.swift" -o "$TMP/rzd" 2>"$TMP/err"; then
  echo "relay build FAILED:"; cat "$TMP/err"; exit 1
fi
"$TMP/rzd" "$RZ_PORT" >"$SRV" 2>&1 & SRVPID=$!
sleep 1

echo "launching A (media :9010) and B (media :9011) — same room, discover via relay, NO peer IP"
open -n --env TRINET_LOG="$A" --env TRINET_RENDEZVOUS="127.0.0.1:$RZ_PORT" --env TRINET_ROOM="$ROOM" \
        --env TRINET_MEDIA_PORT=9010 --env TRINET_TIEBREAK=100 \
        --env TRINET_KC_ACCOUNT=rzA --env TRINET_PINS_KEY=rzA "$APP"
sleep 1
open -n --env TRINET_LOG="$B" --env TRINET_RENDEZVOUS="127.0.0.1:$RZ_PORT" --env TRINET_ROOM="$ROOM" \
        --env TRINET_MEDIA_PORT=9011 --env TRINET_TIEBREAK=200 \
        --env TRINET_KC_ACCOUNT=rzB --env TRINET_PINS_KEY=rzB "$APP"

END=$(( $(date +%s) + SECS )); while [ "$(date +%s)" -lt "$END" ]; do sleep 5; done
pkill -9 -f "TriNetMonitor.app/Contents/MacOS" 2>/dev/null; kill -9 "$SRVPID" 2>/dev/null
clean rzA rzB

echo; echo "=== relay ==="; tail -2 "$SRV" 2>/dev/null
echo "=== A: discovery -> connect ==="; grep -aE "TRINET RZ:|BSD transport up|MITM" "$A" 2>/dev/null | tail -4
echo "=== B: discovery -> connect ==="; grep -aE "TRINET RZ:|BSD transport up|MITM" "$B" 2>/dev/null | tail -4

# Primary media-flow signal: audio DECODED both ways (proves handshake + encrypted transport +
# decode over the rendezvous-discovered pair). Video recv is reported too but can be camera-limited
# in a headless rig (both instances need a live camera).
adec() { grep -aoE "audio sent=[0-9]+ decoded=[0-9]+" "$1" 2>/dev/null | tail -1 | grep -oE "decoded=[0-9]+" | grep -oE "[0-9]+"; }
vrec() { grep -aoE "video sent=[0-9]+ recv=[0-9]+" "$1" 2>/dev/null | tail -1 | grep -oE "recv=[0-9]+" | grep -oE "[0-9]+"; }
AD=$(adec "$A"); BD=$(adec "$B"); AV=$(vrec "$A"); BV=$(vrec "$B")
echo
echo "audio decoded (received):  A=${AD:-0}  B=${BD:-0}    video recv:  A=${AV:-0}  B=${BV:-0}"
if [ "${AD:-0}" -gt 0 ] && [ "${BD:-0}" -gt 0 ]; then
  echo "PASS — encrypted media session established via RENDEZVOUS (audio flowing both ways; discovered by room name alone, no peer IP)"
  exit 0
else
  echo "INCOMPLETE — media session did not flow both ways; see the logs above"
  exit 1
fi
