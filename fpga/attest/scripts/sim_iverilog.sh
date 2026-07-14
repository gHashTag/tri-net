#!/usr/bin/env bash
# sim_iverilog.sh — Ratchet 1/4 sim run for the dna_reader RTL.
#
# Uses Icarus Verilog with a behavioural DNA_PORT stand-in. This proves the
# FSM and shift-out logic is correct in sim. Ratchet 2/4 (real synth) is a
# separate script.
#
# phi^2 + phi^-2 = 3

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUILD="$ROOT/sim/build"
mkdir -p "$BUILD"

cd "$ROOT/sim"
iverilog -g2012 -o "$BUILD/tb_dna_reader.vvp" \
    tb_dna_reader.v dna_port_model.v ../dna_reader.v

# Run and capture output
LOG="$BUILD/tb_dna_reader.log"
vvp "$BUILD/tb_dna_reader.vvp" | tee "$LOG"

if grep -q "ALL 5 CHECKS PASSED" "$LOG" && ! grep -q "^FAIL:" "$LOG"; then
    echo "sim_iverilog: PASS"
    exit 0
else
    echo "sim_iverilog: FAIL" >&2
    exit 2
fi
