#!/bin/bash
source /prjxray/env/bin/activate 2>/dev/null || true
cd /work
PART=xc7z020clg400-1
DB=/nextpnr-xilinx/xilinx/external/prjxray-db/zynq7
for D in prim_ibufds prim_mmcm; do
  echo "################ $D ################"
  yosys -p "read_verilog $D.v; synth_xilinx -top $D -flatten; write_json $D.json" > $D.yosys.log 2>&1 \
    && echo "  1 yosys      : OK" || { echo "  1 yosys      : FAILED"; tail -4 $D.yosys.log; continue; }
  if timeout 1200 nextpnr-xilinx --chipdb /work/xc7z020.bin --xdc $D.xdc \
       --json $D.json --fasm $D.fasm --seed 1 > $D.pnr.log 2>&1; then
    echo "  2 nextpnr     : OK ($(wc -l < $D.fasm) fasm lines)"
  else
    echo "  2 nextpnr     : FAILED"
    grep -iE "error|unsupported|unknown|no bel|cannot" $D.pnr.log | head -4
    continue
  fi
  if fasm2frames --db-root "$DB" --part "$PART" $D.fasm $D.frames > $D.f2f.log 2>&1; then
    echo "  3 fasm2frames : OK"
  else
    echo "  3 fasm2frames : FAILED"; grep -iE "error|unknown|keyerror" $D.f2f.log | head -4; continue
  fi
  if xc7frames2bit --part_file "$DB/$PART/part.yaml" --part_name "$PART" \
       --frm_file $D.frames --output_file $D.bit > $D.bit.log 2>&1; then
    echo "  4 xc7frames2bit: OK ($(stat -c %s $D.bit) bytes)"
  else
    echo "  4 xc7frames2bit: FAILED"; tail -3 $D.bit.log
  fi
done
