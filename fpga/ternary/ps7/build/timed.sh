#!/bin/bash
source /prjxray/env/bin/activate 2>/dev/null || true
cd /work
echo "=== does this nextpnr accept create_clock at all? ==="
nextpnr-xilinx --help 2>&1 | grep -iE "xdc|sdc|clock|timing" | head -5
echo "=== 1. yosys ==="
yosys -p "read_verilog tern_corr8.v tern_corr8_stream.v ps7_corr.v; synth_xilinx -top ps7_corr -flatten; write_json ps7_corr.json" > y.log 2>&1 \
  && echo "  OK" || { echo "  FAILED"; tail -5 y.log; exit 1; }
echo "=== 2. nextpnr WITH timing constraints ==="
timeout 1500 nextpnr-xilinx --chipdb /work/chipdb/xc7z020.bin --xdc ps7_corr_timed.xdc \
  --json ps7_corr.json --fasm /tmp/timed.fasm --seed 1 > timed.log 2>&1
echo "  rc=$?"
echo "--- constraint parsing ---"
grep -iE "create_clock|false_path|unsupported|unknown command|ignor" timed.log | head -6
echo "--- what frequency did it report, and against what target? ---"
grep -iE "Max frequency|target frequency|slack|WNS|critical path" timed.log | head -8
