#!/bin/bash
source /prjxray/env/bin/activate 2>/dev/null || true
cd /work
PART=xc7z020clg400-1; DB=/nextpnr-xilinx/xilinx/external/prjxray-db/zynq7
echo "=== 1 yosys ==="
if yosys -p "read_verilog tern_corr_pn.v tern_corr_pn_stream.v ps7_pn.v; synth_xilinx -top ps7_pn -flatten; write_json ps7_pn.json" > pn.y.log 2>&1; then
  echo "  OK"; grep -E "Number of cells|LUT|FDRE|CARRY4" pn.y.log | tail -5
else echo "  FAILED"; grep -iE "error|warning:" pn.y.log | head -8; exit 1; fi
echo "=== 2 nextpnr (constrained 30.72 MHz) ==="
if timeout 2400 nextpnr-xilinx --chipdb /work/chipdb/xc7z020.bin --xdc ps7_pn.xdc \
     --json ps7_pn.json --fasm ps7_pn.fasm --seed 1 > pn.p.log 2>&1; then
  echo "  OK ($(wc -l < ps7_pn.fasm) fasm lines)"
  grep -iE "Max frequency|ns logic" pn.p.log | tail -4
  grep -A5 "Device utilisation" pn.p.log | head -6
else echo "  FAILED"; grep -iE "error|unroutable|no bel" pn.p.log | head -5; exit 1; fi
echo "=== 3 fasm2frames ==="
fasm2frames --db-root "$DB" --part "$PART" ps7_pn.fasm ps7_pn.frames >/dev/null 2>&1 && echo "  OK" || { echo "  FAILED"; exit 1; }
echo "=== 4 bit ==="
xc7frames2bit --part_file "$DB/$PART/part.yaml" --part_name "$PART" --frm_file ps7_pn.frames --output_file ps7_pn.bit >/dev/null 2>&1 \
  && echo "  OK ($(stat -c %s ps7_pn.bit) bytes)" || echo "  FAILED"
