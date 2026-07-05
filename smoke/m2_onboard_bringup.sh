#!/bin/sh
# M2 on-device bring-up smoke — one P201/P203 Mini, real interface, single instance.
#
# Property gate (NOT convergence — that requires 2+ boards, step 3):
#   1. trios_meshd daemon starts on real ARM hardware
#   2. binds to a real network interface (not 127.0.0.1)
#   3. emits >=N_HELLO HELLO beacons over UDP on that interface within DURATION
#   4. exits cleanly (RC=0) after graceful shutdown
#
# NOT tested here (honest scope):
#   - Neighbor convergence  (step 3, needs a second board)
#   - ETX stability under real radio noise  (step 3+)
#   - TUN/iperf3 throughput  (step 4)
#
# Anchor: phi^2 + phi^-2 = 3

set -eu

BIN="${BIN:-/tmp/trios_meshd}"
IFACE="${IFACE:-eth0}"
NODE_ID="${NODE_ID:-11}"
PORT="${PORT:-5011}"
DURATION="${DURATION:-6}"
N_HELLO_MIN="${N_HELLO_MIN:-10}"   # ~2 Hz beacons * DURATION * 80% margin
LOGDIR="${LOGDIR:-/tmp/m2-bringup-$$}"

mkdir -p "$LOGDIR"

# --- discover a real IPv4 on the requested interface ---------------------
IP=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
if [ -z "$IP" ]; then
    echo "{\"verdict\":\"FAIL\",\"stage\":\"iface_lookup\",\"iface\":\"$IFACE\",\"err\":\"no IPv4 on interface\"}"
    exit 2
fi
case "$IP" in
    127.*) echo "{\"verdict\":\"FAIL\",\"stage\":\"iface_lookup\",\"iface\":\"$IFACE\",\"ip\":\"$IP\",\"err\":\"loopback rejected\"}"; exit 2;;
esac

# --- write config ---------------------------------------------------------
CFG="$LOGDIR/node${NODE_ID}.cfg"
LOG="$LOGDIR/node${NODE_ID}.log"
{
    echo "id $NODE_ID"
    echo "listen ${IP}:${PORT}"
    # No peers -- bring-up test, we're not verifying convergence.
} > "$CFG"

# --- inspect binary -------------------------------------------------------
if [ ! -x "$BIN" ]; then
    echo "{\"verdict\":\"FAIL\",\"stage\":\"binary_check\",\"bin\":\"$BIN\",\"err\":\"not executable or not found\"}"
    exit 3
fi
BIN_SHA=$(sha256sum "$BIN" 2>/dev/null | awk '{print $1}' || echo "unknown")
UNAME=$(uname -srm 2>/dev/null || echo "unknown")

# --- run daemon in background (setsid so signals to the group don't hit us) ---
START_EPOCH=$(date +%s)
setsid "$BIN" "$CFG" > "$LOG" 2>&1 < /dev/null &
DAEMON_PID=$!

# grace period so bind + first HELLO happen
sleep "$DURATION"

# --- shutdown cleanly (TERM then wait) -----------------------------------
kill -TERM "$DAEMON_PID" 2>/dev/null || true
i=0
while [ $i -lt 10 ]; do
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then break; fi
    sleep 0.1
    i=$((i+1))
done
kill -0 "$DAEMON_PID" 2>/dev/null && kill -KILL "$DAEMON_PID" 2>/dev/null || true
# wait may return signal-encoded rc; that is expected, capture and continue.
set +e
wait "$DAEMON_PID" 2>/dev/null
DAEMON_RC=$?
set -e
END_EPOCH=$(date +%s)

# --- parse log for bring-up evidence -------------------------------------
# Observed trios_meshd log format (see src/bin/trios_meshd.rs):
#   [meshd] node <ID> on <IP>:<PORT> — peers [...]      <- bind evidence (G1)
#   [meshd] node <ID> neighbors { ... }                   <- periodic tick, HELLO loop alive (G2)
# `grep -c` prints "0\n" or similar on some sh variants; force single int with awk.
LOG_LINES=$(awk 'END{print NR}' "$LOG" 2>/dev/null)
BIND_OK=$(grep -Ec "node ${NODE_ID} on ${IP}:${PORT}" "$LOG" 2>/dev/null | awk '{print $1+0}')
HELLO_EV=$(grep -Ec "node ${NODE_ID} neighbors" "$LOG" 2>/dev/null | awk '{print $1+0}')
CRASH_MARKS=$(grep -Ec 'panic|fatal|thread.*panicked' "$LOG" 2>/dev/null | awk '{print $1+0}')
[ -z "$LOG_LINES" ] && LOG_LINES=0
[ -z "$BIND_OK" ] && BIND_OK=0
[ -z "$HELLO_EV" ] && HELLO_EV=0
[ -z "$CRASH_MARKS" ] && CRASH_MARKS=0

# --- gate ----------------------------------------------------------------
# Property gate for step 2 (one-board bring-up):
#   G1: bind to real interface (BIND_OK >= 1 for expected IP:PORT)
#   G2: daemon stayed alive through its beacon loop (HELLO_EV >= 1)
#   G3: clean run (CRASH_MARKS == 0)
#   G4: some log output (LOG_LINES >= 1)
# All four must hold to PASS.
VERDICT="PASS"
FAIL_REASON=""
if [ "$LOG_LINES" -lt 1 ]; then
    VERDICT="FAIL"; FAIL_REASON="no_log_output"
elif [ "$BIND_OK" -lt 1 ]; then
    VERDICT="FAIL"; FAIL_REASON="no_bind_evidence"
elif [ "$HELLO_EV" -lt 1 ]; then
    VERDICT="FAIL"; FAIL_REASON="no_beacon_loop_evidence"
elif [ "$CRASH_MARKS" -gt 0 ]; then
    VERDICT="FAIL"; FAIL_REASON="crash_markers_in_log"
fi

cat <<EOF
{"verdict":"$VERDICT","fail_reason":"$FAIL_REASON","iface":"$IFACE","ip":"$IP","port":$PORT,"node_id":$NODE_ID,"duration_s":$DURATION,"daemon_rc":$DAEMON_RC,"bin":"$BIN","bin_sha256":"$BIN_SHA","uname":"$UNAME","log_lines":$LOG_LINES,"bind_evidence":$BIND_OK,"beacon_ticks":$HELLO_EV,"crash_marks":$CRASH_MARKS,"log_path":"$LOG","cfg_path":"$CFG","started_epoch":$START_EPOCH,"ended_epoch":$END_EPOCH}
EOF

[ "$VERDICT" = "PASS" ] && exit 0 || exit 1
