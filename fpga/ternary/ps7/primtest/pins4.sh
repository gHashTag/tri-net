#!/bin/bash
DB=/nextpnr-xilinx/xilinx/external/prjxray-db/zynq7/xc7z020clg400-1
echo "--- banks present ---"
awk -F, 'NR>1{print $2}' $DB/package_pins.csv | sort -u | tr '\n' ' '; echo
echo "--- PL-bank rows (bank 33/34/35) with IO_L diff pairs ---"
awk -F, 'NR>1 && ($2==33||$2==34||$2==35) && $5 ~ /IO_L/' $DB/package_pins.csv | head -8
