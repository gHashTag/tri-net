#!/usr/bin/env bash
# synth_yosys.sh — Ratchet 2/4 synth attempt via openXC7 (yosys + nextpnr).
#
# openXC7 handles xc7a200t (AX7203) end-to-end without vendor Vivado. This
# script drives just the yosys front-end and dumps the synth JSON so we
# can see whether DNA_PORT is recognised.
#
# Prerequisites (on the host that runs this — sandbox is not one of them):
#   - yosys 0.35+ (built with --enable-openxc7 or plain xilinx pass)
#   - openXC7 chipdb for xc7a200t
#   - nextpnr-xilinx (or nextpnr-fpga-interchange for xc7)
#   - prjxray-db for artix7
#
# Usage:
#   ./synth_yosys.sh 2>&1 | tee ../build/synth.log
#
# Output:
#   ../build/dna_reader.json     — synth-out netlist
#   ../build/dna_reader.stat     — yosys stat report (LUT/FF counts)
#   ../build/dna_reader.blif     — optional intermediate
#
# Ratchet 2/4 gate: yosys completes without ERROR, DNA_PORT primitive is
# either inferred or emitted as a black-box cell. If DNA_PORT is silently
# dropped, that's a Ratchet-2 FAIL and must be captured in the report.
#
# phi^2 + phi^-2 = 3

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUILD="$ROOT/build"
mkdir -p "$BUILD"

RTL="$ROOT/dna_reader.v"
TOP="dna_reader"

if ! command -v yosys >/dev/null 2>&1; then
  echo "yosys not installed. Ratchet 2/4 marked BLOCKED-toolchain in the report." >&2
  exit 3
fi

# Yosys script. `read_verilog -defer` because DNA_PORT is a vendor black box.
cat > "$BUILD/synth.ys" <<EOF
read_verilog -defer $RTL
hierarchy -check -top $TOP
proc; opt; fsm; opt; memory; opt
# Xilinx 7-series techmap; requires yosys built with Xilinx flow.
synth_xilinx -top $TOP -family xc7
stat
write_json $BUILD/dna_reader.json
write_blif $BUILD/dna_reader.blif
EOF

yosys -q -l "$BUILD/synth.log" -s "$BUILD/synth.ys"
grep -E "Number of cells|DNA_PORT|ERROR" "$BUILD/synth.log" | tee "$BUILD/dna_reader.stat"

echo "Ratchet 2/4 yosys stage completed. Review $BUILD/synth.log for DNA_PORT handling."
