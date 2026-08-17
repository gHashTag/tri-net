#!/bin/bash
source /prjxray/env/bin/activate 2>/dev/null || true
cd /work
PART=xc7z020clg400-1; DB=/nextpnr-xilinx/xilinx/external/prjxray-db/zynq7
echo "=== yosys ==="
if yosys -p "read_verilog tern_corr_pn.v tern_corr_pn_tree.v ps7_speed.v; synth_xilinx -top ps7_speed -flatten; write_json ps7_speed.json" > sp.y.log 2>&1; then
  echo "  OK"; grep -E "  LUT[456]|  CARRY4|  FDRE|  RAMB" sp.y.log | tail -6
else echo "  FAILED"; grep -iE "^ERROR|error:" sp.y.log | head -8; exit 1; fi
echo "=== nextpnr at 30.72 MHz ==="
if timeout 2400 nextpnr-xilinx --chipdb /work/chipdb/xc7z020.bin --xdc ps7_speed.xdc \
     --json ps7_speed.json --fasm ps7_speed.fasm --seed 1 > sp.p.log 2>&1; then
  echo "  PASS"; grep -iE "Max frequency|ns logic" sp.p.log | tail -3
  grep -A4 "Device utilisation" sp.p.log | head -5
else echo "  FAILED"; grep -iE "Max frequency|ERROR" sp.p.log | tail -3; exit 1; fi
echo "=== frames + bit ==="
fasm2frames --db-root "$DB" --part "$PART" ps7_speed.fasm ps7_speed.frames >/dev/null 2>&1 && echo "  frames OK" || { echo "  frames FAILED"; exit 1; }
xc7frames2bit --part_file "$DB/$PART/part.yaml" --part_name "$PART" --frm_file ps7_speed.frames --output_file ps7_speed.bit >/dev/null 2>&1 \
  && echo "  bit OK ($(stat -c %s ps7_speed.bit) bytes)" || echo "  bit FAILED"
