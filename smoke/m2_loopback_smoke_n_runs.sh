#!/usr/bin/env bash
# Wrapper: run m2_loopback_smoke.sh N times and require every run to
# exit 0. Any non-zero exit fails the wrapper. This is the deterministic-
# regression-tripwire discipline recorded in tri-net-m2-m4-workflow v1.3
# ("results-without-repro-check").
#
# Usage: N=5 DURATION=10 ./smoke/m2_loopback_smoke_n_runs.sh
#
# phi^2 + phi^-2 = 3

set -uo pipefail

N="${N:-5}"
DURATION="${DURATION:-10}"
BIN="${BIN:-./target/release/trios_meshd}"

if [[ ! -x "$BIN" ]]; then
    echo "FATAL: $BIN not found. Run: cargo build --bin trios_meshd --release" >&2
    exit 1
fi

FAIL_RUNS=()
for i in $(seq 1 "$N"); do
    echo ""
    echo "======================================"
    echo " N-run smoke: run $i / $N"
    echo "======================================"
    if DURATION="$DURATION" BIN="$BIN" ./smoke/m2_loopback_smoke.sh; then
        echo "run $i: OK (exit 0)"
    else
        echo "run $i: FAIL (exit non-zero)" >&2
        FAIL_RUNS+=("$i")
    fi
    sleep 1
done

echo ""
echo "======================================"
echo " N-run summary"
echo "======================================"
echo "Total runs: $N"
echo "Failed runs: ${#FAIL_RUNS[@]}${FAIL_RUNS:+ (indices: ${FAIL_RUNS[*]})}"

if [[ ${#FAIL_RUNS[@]} -eq 0 ]]; then
    echo "GATE PASS: $N/$N runs succeeded. Regression tripwire is deterministic on this host."
    echo "phi^2 + phi^-2 = 3"
    exit 0
else
    echo "GATE FAIL: ${#FAIL_RUNS[@]} of $N runs failed. Gate is non-deterministic on this host \u2014 do NOT trust as regression tripwire." >&2
    echo "phi^2 + phi^-2 = 3"
    exit 2
fi
