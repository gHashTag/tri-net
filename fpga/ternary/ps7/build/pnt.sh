#!/bin/bash
source /prjxray/env/bin/activate 2>/dev/null || true
cd /work
PART=xc7z020clg400-1; DB=/nextpnr-xilinx/xilinx/external/prjxray-db/zynq7
echo "=== yosys (tree variant, 63 taps) ==="
if yosys -p "read_verilog tern_corr_pn.v tern_corr_pn_tree.v ps7_pn_tree.v; synth_xilinx -top ps7_pn_tree -flatten; write_json ps7_pn_tree.json" > pnt.y.log 2>&1; then
  echo "  OK"; grep -E "  LUT[456]|  CARRY4|  FDRE" pnt.y.log | tail -5
else echo "  FAILED"; grep -iE "error" pnt.y.log | head -6; exit 1; fi
echo "=== nextpnr, constrained at 30.72 MHz ==="
if timeout 2400 nextpnr-xilinx --chipdb /work/chipdb/xc7z020.bin --xdc ps7_pn_tree.xdc \
     --json ps7_pn_tree.json --fasm ps7_pn_tree.fasm --seed 1 > pnt.p.log 2>&1; then
  echo "  PASS ($(wc -l < ps7_pn_tree.fasm) fasm lines)"
  grep -iE "Max frequency|ns logic" pnt.p.log | tail -3
  grep -A4 "Device utilisation" pnt.p.log | head -5
else
  echo "  did not pass"; grep -iE "Max frequency|ERROR" pnt.p.log | tail -3
fi
