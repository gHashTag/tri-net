#!/bin/bash
DB=/nextpnr-xilinx/xilinx/external/prjxray-db/zynq7/xc7z020clg400-1
echo "--- clock-capable differential pairs (MRCC/SRCC) ---"
awk -F, 'NR>1 && ($5 ~ /MRCC/ || $5 ~ /SRCC/)' $DB/package_pins.csv | head -10
