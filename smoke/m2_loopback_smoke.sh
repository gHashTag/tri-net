#!/usr/bin/env bash
# M2 loopback smoke — sanity-check trios_meshd UDP transport on a single host.
#
# 3 nodes on loopback (127.0.0.1:5011-5013), fully connected topology.
# All traffic stays inside the machine — no radios, no external network.
# This is *not* a hardware M2 datapoint (still `-sim`), but it validates that
# daemon startup + HELLO discovery + ETX table code path runs end-to-end
# without segfaults or config errors before we push to the 3 boards.
#
# Anchor: phi^2 + phi^-2 = 3

set -euo pipefail

BIN="${BIN:-./target/release/trios_meshd}"
LOGDIR="$(mktemp -d /tmp/m2-loopback-XXXX)"
DURATION="${DURATION:-8}"

if [[ ! -x "$BIN" ]]; then
    echo "FATAL: $BIN not found. Run: cargo build --bin trios_meshd --release" >&2
    exit 1
fi

cleanup() {
    echo "[cleanup] killing daemons..."
    kill $(jobs -p) 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT

for ID in 11 12 13; do
    CFG="$LOGDIR/node${ID}.cfg"
    LOG="$LOGDIR/node${ID}.log"
    {
        echo "id $ID"
        echo "listen 127.0.0.1:50${ID}"
        for PEER in 11 12 13; do
            [[ "$PEER" == "$ID" ]] && continue
            echo "peer $PEER 127.0.0.1:50${PEER}"
        done
    } > "$CFG"
    "$BIN" "$CFG" > "$LOG" 2>&1 &
    echo "[start] node $ID pid=$! log=$LOG"
    sleep 0.1  # tiny stagger — avoid race where node-N starts before peer sockets bind
done

sleep "$DURATION"

echo ""
echo "=== per-node log summary (last 12 lines) ==="
for ID in 11 12 13; do
    echo "--- node $ID ---"
    tail -12 "$LOGDIR/node${ID}.log" || echo "(empty)"
    echo
done

echo "=== HELLO / neighbor discovery counts ==="
for ID in 11 12 13; do
    HELLO_TX=$(grep -c "HELLO" "$LOGDIR/node${ID}.log" 2>/dev/null || echo 0)
    NEIGH=$(grep -c -E "neighbor|added-link|link-up" "$LOGDIR/node${ID}.log" 2>/dev/null || echo 0)
    echo "node $ID: HELLO-lines=$HELLO_TX  neighbor-events=$NEIGH"
done

echo ""
echo "=== return codes ==="
for ID in 11 12 13; do
    PID=$(pgrep -f "trios_meshd.*node${ID}.cfg" 2>/dev/null || true)
    if [[ -n "$PID" ]]; then
        echo "node $ID: RUNNING (pid $PID)"
    else
        echo "node $ID: EXITED prematurely — check $LOGDIR/node${ID}.log"
    fi
done

echo ""
# ---------------------------------------------------------------------------
# REGRESSION GATE (v2): visibility with finite ETX in the last N samples.
#
# What the SocketAddr fix guarantees deterministically:
#   1. Every node learns BOTH peers (no IpAddr collision suppressing one).
#   2. Both link-ETX values are FINITE (WMEWMA est > DEAD_EPS = 0.15 both
#      directions).
#
# What the fix does NOT guarantee (and the ETX algorithm does not promise):
#   - Steady ETX = 1.00. WMEWMA with alpha=0.5, HELLO period 300 ms,
#     ETX_WINDOW = 3 will bounce for 3-4 ticks after ANY single dropped
#     HELLO on any real channel (loopback, radio, tunnel). A single-sample
#     "tail -1 == 1.0x" gate is non-deterministic by construction.
#
# Reference: WMEWMA rationale (Woo, Tong & Culler, SenSys 2003;
# Rosati et al., arXiv:1307.6350). Confirmed empirically: reviewer saw
# node-11 report {13=2.03} on run #1 and {13=1.00} on run #2, same binary,
# same host, back-to-back.
#
# This gate accepts the last N=5 neighbors-samples per node and requires
# that in EVERY sample both peers are present with a finite numeric ETX.
# Any missing peer, ANY infinite ETX ("inf"), or fewer than N samples =>
# gate fails with exit 2.
#
# Historic defect (pre-2026-07-05): keying on IpAddr collided on loopback,
# leaving node-11 isolated. Fix moved the map to SocketAddr. This gate is
# the tripwire against that regression.
#
# phi^2 + phi^-2 = 3
# ---------------------------------------------------------------------------
echo ""
echo "=== triangle visibility gate (v2: last N=5 samples, finite ETX) ==="
SAMPLES_REQUIRED=5
GATE_FAIL=0
for ID in 11 12 13; do
    # All neighbors lines for this node, take the last N.
    LAST_N=$(grep "neighbors" "$LOGDIR/node${ID}.log" | tail -${SAMPLES_REQUIRED})
    NLINES=$(echo -n "$LAST_N" | grep -c "neighbors" || true)
    if [[ "$NLINES" -lt "$SAMPLES_REQUIRED" ]]; then
        echo "node $ID: FAIL — only $NLINES neighbors samples (need $SAMPLES_REQUIRED)"
        GATE_FAIL=1
        continue
    fi
    NODE_FAIL=0
    SAMPLE_IDX=0
    while IFS= read -r LINE; do
        SAMPLE_IDX=$((SAMPLE_IDX + 1))
        # For each peer, require: PEER=<finite-float>. Reject "inf" and missing.
        for PEER in 11 12 13; do
            [[ "$PEER" == "$ID" ]] && continue
            # Match PEER=<digits>.<digits> (finite decimal). Reject inf/INF/NaN.
            if ! echo "$LINE" | grep -qE "${PEER}=[0-9]+\.[0-9]+"; then
                echo "node $ID: FAIL sample #${SAMPLE_IDX} — peer $PEER missing or non-finite ($LINE)"
                NODE_FAIL=1
            elif echo "$LINE" | grep -qiE "${PEER}=(inf|nan)"; then
                echo "node $ID: FAIL sample #${SAMPLE_IDX} — peer $PEER has non-finite ETX ($LINE)"
                NODE_FAIL=1
            fi
        done
    done <<< "$LAST_N"
    if [[ "$NODE_FAIL" -eq 0 ]]; then
        LAST_ONE=$(echo "$LAST_N" | tail -1)
        echo "node $ID: PASS — both peers visible with finite ETX across last $SAMPLES_REQUIRED samples (last: $LAST_ONE)"
    else
        GATE_FAIL=1
    fi
done

echo ""
echo "logs preserved at: $LOGDIR"
echo "smoke duration: ${DURATION}s"
echo ""
echo "phi^2 + phi^-2 = 3"

if [[ "$GATE_FAIL" -ne 0 ]]; then
    echo ""
    echo "SMOKE GATE FAILED — three-node triangle did not converge." >&2
    exit 2
fi
