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
echo "logs preserved at: $LOGDIR"
echo "smoke duration: ${DURATION}s"
echo ""
echo "phi^2 + phi^-2 = 3"
