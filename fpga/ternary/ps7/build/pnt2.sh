#!/bin/bash
source /prjxray/env/bin/activate 2>/dev/null || true
cd /work
PART=xc7z020clg400-1; DB=/nextpnr-xilinx/xilinx/external/prjxray-db/zynq7
echo "=== fasm2frames ==="
fasm2frames --db-root "$DB" --part "$PART" ps7_pn_tree.fasm ps7_pn_tree.frames > f.log 2>&1 \
  && echo "  OK ($(wc -l < ps7_pn_tree.frames) frame lines)" \
  || { echo "  FAILED"; grep -oE "FasmInconsistentBits.*|KeyError.*" f.log | head -2; exit 1; }
echo "=== xc7frames2bit ==="
xc7frames2bit --part_file "$DB/$PART/part.yaml" --part_name "$PART" \
  --frm_file ps7_pn_tree.frames --output_file ps7_pn_tree.bit > b.log 2>&1 \
  && echo "  OK ($(stat -c %s ps7_pn_tree.bit) bytes)" || { echo "  FAILED"; tail -3 b.log; }
