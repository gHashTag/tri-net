#!/bin/bash
source /prjxray/env/bin/activate 2>/dev/null || true
cd /work
PART=xc7z020clg400-1; DB=/nextpnr-xilinx/xilinx/external/prjxray-db/zynq7
for M in A B; do
  D=ps7_pn_mut$M
  echo "########## mutant $M ##########"
  yosys -p "read_verilog tern_corr_pn.v mut${M}_core.v $D.v; synth_xilinx -top $D -flatten; write_json $D.json" > $D.y.log 2>&1 \
    && echo "  yosys OK" || { echo "  yosys FAILED"; grep -iE "^ERROR" $D.y.log | head -3; continue; }
  nextpnr-xilinx --chipdb /work/chipdb/xc7z020.bin --xdc $D.xdc --json $D.json --fasm $D.fasm --seed 1 > $D.p.log 2>&1 \
    && echo "  nextpnr OK  $(grep -oE "Max frequency[^)]*\)" $D.p.log | tail -1)" || { echo "  nextpnr FAILED"; grep -iE "ERROR" $D.p.log|head -2; continue; }
  fasm2frames --db-root "$DB" --part "$PART" $D.fasm $D.frames >/dev/null 2>&1 && echo "  frames OK" || { echo "  frames FAILED"; continue; }
  xc7frames2bit --part_file "$DB/$PART/part.yaml" --part_name "$PART" --frm_file $D.frames --output_file $D.bit >/dev/null 2>&1 \
    && echo "  bit OK ($(stat -c %s $D.bit) bytes)" || echo "  bit FAILED"
done
