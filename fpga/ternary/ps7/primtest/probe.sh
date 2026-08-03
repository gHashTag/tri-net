#!/bin/bash
source /prjxray/env/bin/activate 2>/dev/null || true
cd /work
PART=xc7z020clg400-1
DB=/nextpnr-xilinx/xilinx/external/prjxray-db/zynq7
for D in prim_ibufds prim_mmcm; do
  echo "################ $D ################"
  echo "--- 1. yosys ---"
  if yosys -p "read_verilog $D.v; synth_xilinx -top $D -flatten; write_json $D.json" > $D.yosys.log 2>&1; then
    echo "  yosys: OK"
    grep -iE "IBUFDS|MMCME2|BUFG" $D.yosys.log | tail -3
  else
    echo "  yosys: FAILED"; tail -6 $D.yosys.log; continue
  fi
  echo "--- 2. nextpnr ---"
  : > $D.xdc
  if timeout 900 nextpnr-xilinx --chipdb /work/xc7z020.bin --xdc $D.xdc \
       --json $D.json --fasm $D.fasm --seed 1 > $D.pnr.log 2>&1; then
    echo "  nextpnr: OK  ($(wc -l < $D.fasm) fasm lines)"
  else
    echo "  nextpnr: FAILED"
    grep -iE "error|unsupported|unknown|not supported|no bel" $D.pnr.log | head -6
  fi
done
