#!/bin/bash
# Five COMPLETE builds of ps7_pn_tree, not five runs of the last stage.
# This is what "byte-reproducible end to end" actually requires, and what the
# earlier five-run experiment did not do.
source /prjxray/env/bin/activate 2>/dev/null || true
cd /work
PART=xc7z020clg400-1
DB=/nextpnr-xilinx/xilinx/external/prjxray-db/zynq7
for i in 1 2 3 4 5; do
  echo "########## full build $i of 5 ##########"
  yosys -p "read_verilog tern_corr_pn.v tern_corr_pn_tree.v ps7_pn_tree.v; synth_xilinx -top ps7_pn_tree -flatten; write_json f$i.json" > f$i.y.log 2>&1 || { echo "yosys FAILED"; continue; }
  nextpnr-xilinx --chipdb /work/chipdb/xc7z020.bin --xdc ps7_pn_tree.xdc --json f$i.json --fasm f$i.fasm --seed 1 > f$i.p.log 2>&1 || { echo "nextpnr FAILED"; continue; }
  fasm2frames --db-root "$DB" --part "$PART" f$i.fasm f$i.frames > /dev/null 2>&1 || { echo "fasm2frames FAILED"; continue; }
  xc7frames2bit --part_file "$DB/$PART/part.yaml" --part_name "$PART" --frm_file f$i.frames --output_file f$i.bit > /dev/null 2>&1 || { echo "bit FAILED"; continue; }
  echo "  json  $(sha256sum f$i.json   | cut -c1-16)"
  echo "  fasm  $(sha256sum f$i.fasm   | cut -c1-16)"
  echo "  frames $(sha256sum f$i.frames | cut -c1-16)"
  echo "  bit   $(sha256sum f$i.bit    | cut -c1-16)"
  grep -oE "Max frequency for clock 'FCLKCLK\[0\]': [0-9.]+ MHz" f$i.p.log | tail -1
done
echo "########## summary ##########"
for s in json fasm frames bit; do
  echo "$s distinct hashes: $(sha256sum f*.$s 2>/dev/null | awk '{print $1}' | sort -u | wc -l) of 5"
done
