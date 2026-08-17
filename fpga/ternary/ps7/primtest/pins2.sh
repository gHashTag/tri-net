#!/bin/bash
DB=/nextpnr-xilinx/xilinx/external/prjxray-db/zynq7/xc7z020clg400-1
echo "--- header ---"; head -1 $DB/package_pins.csv
echo "--- a differential pair (look for _P / _N in the same bank) ---"
grep -iE "_P[0-9]*," $DB/package_pins.csv | head -4
echo "..."
grep -iE "_N[0-9]*," $DB/package_pins.csv | head -4
echo "--- total pins ---"; wc -l < $DB/package_pins.csv
