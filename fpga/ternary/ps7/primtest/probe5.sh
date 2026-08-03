#!/bin/bash
source /prjxray/env/bin/activate 2>/dev/null || true
cd /work
PART=xc7z020clg400-1; DB=/nextpnr-xilinx/xilinx/external/prjxray-db/zynq7
D=prim_iserdes
echo "############ $D ############"
yosys -p "read_verilog $D.v; synth_xilinx -top $D -flatten; write_json $D.json" > $D.y.log 2>&1 \
  && echo "  yosys       : OK" || { echo "  yosys: FAILED"; grep -iE "error" $D.y.log|head -3; exit; }
if timeout 900 nextpnr-xilinx --chipdb /work/xc7z020.bin --xdc $D.xdc --json $D.json --fasm $D.fasm --seed 1 > $D.p.log 2>&1; then
  echo "  nextpnr     : OK ($(wc -l < $D.fasm) lines)"
else echo "  nextpnr     : FAILED"; grep -iE "error|unsupported|no bel" $D.p.log|head -3; exit; fi
if fasm2frames --db-root "$DB" --part "$PART" $D.fasm $D.frames > $D.f.log 2>&1; then echo "  fasm2frames : OK"
else echo "  fasm2frames : FAILED"; grep -oE "FasmInconsistentBits.*|KeyError.*" $D.f.log|head -2; exit; fi
xc7frames2bit --part_file "$DB/$PART/part.yaml" --part_name "$PART" --frm_file $D.frames --output_file $D.bit >/dev/null 2>&1 \
  && echo "  bit         : OK ($(stat -c %s $D.bit) bytes)" || echo "  bit: FAILED"
