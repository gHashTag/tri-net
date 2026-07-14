#!/usr/bin/env bash
# A2 Ratchet 2/4 smoke — probe for FPGA toolchain (yosys, nextpnr-xilinx,
# vivado) and either exercise the synth flow or exit with a well-defined
# BLOCKED-toolchain status. The gate here is honest: sandbox has no
# toolchain, so this script's purpose is to make that state a first-class
# smoke artifact rather than a silent gap.
#
# Ratchet position after this smoke:
#   1/4 sandbox verified   — iverilog sim (see sim_iverilog.sh)
#   2/4 synth attempted    — this smoke (BLOCKED unless toolchain present)
#   3/4 one-board device   — requires AX7203 + openXC7 flash
#   4/4 two-board device   — requires two AX7203 boards
#
# phi^2 + phi^-2 = 3

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

pass() { printf "  [PASS] %s\n" "$1"; }
info() { printf "  [INFO] %s\n" "$1"; }

echo "[smoke] probing FPGA toolchain"

HAVE_YOSYS=0
HAVE_NEXTPNR=0
HAVE_VIVADO=0
command -v yosys >/dev/null 2>&1 && HAVE_YOSYS=1
command -v nextpnr-xilinx >/dev/null 2>&1 && HAVE_NEXTPNR=1
command -v vivado >/dev/null 2>&1 && HAVE_VIVADO=1

info "yosys=$HAVE_YOSYS nextpnr-xilinx=$HAVE_NEXTPNR vivado=$HAVE_VIVADO"

if [[ $HAVE_YOSYS -eq 1 ]]; then
  echo "[smoke] yosys present — running openXC7 synth"
  mkdir -p fpga/attest/build
  bash fpga/attest/scripts/synth_yosys.sh 2>&1 | tail -20
  pass "yosys synth completed"
elif [[ $HAVE_VIVADO -eq 1 ]]; then
  echo "[smoke] vivado present — running Vivado batch"
  bash -c 'cd fpga/attest && vivado -mode batch -source scripts/synth_vivado.tcl' 2>&1 | tail -20
  pass "vivado synth completed"
else
  # Honest structural status: no toolchain, no synth. Not a FAIL — the
  # smoke is showing the ratchet is BLOCKED-toolchain, which is what the
  # anti-anchor discipline demands we surface rather than paper over.
  echo "[smoke] BLOCKED-toolchain — no yosys and no vivado in PATH"
  info "R2/4 gate: waiting on external host with FPGA toolchain"
  info "sandbox coverage: A2 R1/4 iverilog (see smoke/sim_iverilog PASS)"
  info "next runtime move: run this smoke on ssdm4 macbook or CI with openXC7"
  # Exit 0 with explicit BLOCKED status. Detected by grep 'BLOCKED-toolchain'
  # in dashboards. R2/4 is not asserted PASSED by the sandbox.
  exit 0
fi

echo "[smoke] synth ratchet 2/4 completed"
