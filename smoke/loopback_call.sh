#!/bin/bash
# smoke/loopback_call.sh — headless end-to-end smoke test of the TriNetMonitor video-call path.
#
# Sends a 3-participant INVITE listing 127.0.0.1 to the app's idle listener; the app auto-joins the
# "group" and group-calls itself, so its OWN video loops back through the FULL pipeline:
#   camera -> encoder -> fragment -> seal -> UDP -> unseal -> reassemble -> per-source decoder,
# and the BWE receiver-reports flow both ways. PASS = the app decodes its own video within the
# timeout. This is the cheapest true e2e video test that exists without a second device.
#
# Usage: ./smoke/loopback_call.sh          (app must be installed at /Applications/TriNetMonitor.app)
# Exit:  0 = PASS, 1 = FAIL (with the relevant log tail printed)

set -u
LOG="$HOME/Library/Logs/TriNetMonitor/monitor.log"
APP="/Applications/TriNetMonitor.app"
TIMEOUT_S=30

fail() { echo "FAIL: $1"; echo "--- log tail ---"; tail -15 "$LOG" 2>/dev/null; exit 1; }

[ -d "$APP" ] || fail "app not installed at $APP"

# Scope every log check to lines AFTER this marker (the log spans DAYS — full date required).
# Taken BEFORE the restart so the fresh instance's own startup lines are inside the window.
MARK=$(date "+%Y-%m-%d %H:%M:%S")
since() { awk -v m="$MARK" '$0 >= m' "$LOG" 2>/dev/null; }

# Fresh app instance so :7000 is an idle listener (not a stale call). Do NOT trust a blind sleep:
# the dying instance can hold :7000 for up to its 1s recv timeout, and a fresh instance that loses
# the bind race skips its listener. HANDSHAKE WITH THE LOG: wait for a fresh "idle listener up".
# Kill EVERY TriNetMonitor binary, wherever it was launched from — ghost instances running out of
# build dirs share the log and steal :7000, and a path-scoped pkill misses them.
pkill -f "TriNetMonitor" 2>/dev/null
sleep 2
open -n "$APP"
deadline=$(( $(date +%s) + 15 ))
until since | grep -q "idle listener up"; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "fresh instance never bound :7000 (no 'idle listener up' after restart)"
    sleep 1
done

# 3-participant INVITE (magic FD 11 + "name\nip1,ip2,ip3\nroom") -> participants>2 -> auto-join.
# MUST be ONE datagram: bash printf > /dev/udp issues MULTIPLE write()s, which UDP turns into
# MULTIPLE datagrams — the first carries only the magic+name, so the app rings a participant-less
# call instead of auto-joining (a pipe coalesces writes, so xxd shows identical bytes — the socket
# does not). python's single sendto() guarantees one datagram. Re-sent every ~4s (UDP is lossy).
send_invite() {
    python3 - <<'PYEOF'
import socket, hashlib, hmac, time
# The INVITE is authenticated + fresh (see CallManager.inviteKey): [FD 11][HMAC:8][name\nips\nROOM\nTS_MS].
# Derive the same PSK -> HKDF -> HMAC key AND stamp a current timestamp; unauthenticated OR stale is rejected.
def hkdf(ikm, salt, info, n=32):
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    okm, t, i = b"", b"", 1
    while len(okm) < n:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest(); okm += t; i += 1
    return okm[:n]
key = hkdf(hashlib.sha256(b"tri-net-psk-v1").digest(), b"trios-mesh/v1/invite", b"invite-auth")
ts = str(int(time.time() * 1000)).encode()
payload = b"LOOPBACK smoke\n127.0.0.1,192.168.1.250,192.168.1.251\n\n" + ts
mac = hmac.new(key, payload, hashlib.sha256).digest()[:8]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(bytes([0xFD, 0x11]) + mac + payload, ("127.0.0.1", 7000))
s.close()
PYEOF
}
send_invite || fail "could not send INVITE to :7000"

deadline=$(( $(date +%s) + TIMEOUT_S ))
tick=0
# PASS = OUR video decoded end-to-end after the invite. The group tile marker is the strongest
# proof, but a 1-1 self-call decode ("FIRST FRAME DECODED") exercises the same pipeline.
while [ "$(date +%s)" -lt "$deadline" ]; do
    if since | grep -qE "GROUP video from 127.0.0.1|FIRST FRAME DECODED"; then
        echo "PASS: loopback video decoded end-to-end"
        since | grep -E "auto-joining|accepting call|GROUP transport|GROUP video|FIRST FRAME|BWE" | head -6
        # End the self-call: back to a clean idle instance.
        pkill -f "TriNetMonitor" 2>/dev/null
        sleep 1
        open -n "$APP"
        exit 0
    fi
    tick=$((tick + 1))
    [ $((tick % 2)) -eq 0 ] && send_invite
    sleep 2
done

fail "no decoded loopback video within ${TIMEOUT_S}s"
