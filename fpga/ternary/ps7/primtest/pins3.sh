#!/bin/bash
DB=/nextpnr-xilinx/xilinx/external/prjxray-db/zynq7/xc7z020clg400-1
echo "--- first 12 data rows ---"
sed -n '2,13p' $DB/package_pins.csv
echo "--- rows whose pin_function mentions a diff pair ---"
awk -F, 'NR>1 && ($5 ~ /_P/ || $5 ~ /_N/)' $DB/package_pins.csv | head -6
