#!/bin/bash
source /prjxray/env/bin/activate 2>/dev/null || true
DB=/nextpnr-xilinx/xilinx/external/prjxray-db/zynq7
PART=xc7z020clg400-1
echo "--- part dir contents ---"; ls $DB/$PART/ 2>/dev/null | head
echo "--- package pin files anywhere ---"
find $DB -iname "*package*" -o -iname "*pin*" 2>/dev/null | head -5
echo "--- sample of pins from part.yaml ---"
grep -iE "^\s+(A|B|C|D|E)[0-9]+:|pin|iob" $DB/$PART/part.yaml 2>/dev/null | head -12
echo "--- differential pair hints ---"
grep -icE "_p\b|_n\b|DIFF" $DB/$PART/part.yaml 2>/dev/null
