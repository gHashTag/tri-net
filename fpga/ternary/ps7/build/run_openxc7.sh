#!/bin/bash
# Phase A: reproduce ps7_tern.bit through the fully open flow (no Vivado).
# Runs INSIDE regymm/openxc7. Every step logged with timing and hashes.
set -euo pipefail
source /prjxray/env/bin/activate 2>/dev/null || true
cd /work
PART=xc7z020clg400-1
DEVICE=xc7z020
DB=/nextpnr-xilinx/xilinx/external/prjxray-db/zynq7
CHIPDB=/work/chipdb

echo "=== openXC7 reproduction run: $(date -u +%FT%TZ) ==="
echo "--- versions ---"
yosys -V
nextpnr-xilinx --version 2>&1 | head -1 || true
echo "prjxray-db zynq7: $(ls -d $DB)"

mkdir -p "$CHIPDB"
if [ ! -f "$CHIPDB/$DEVICE.bin" ]; then
  echo "=== 0/5 chipdb generation (this is the slow step) ==="
  export XRAY_DIR=/prjxray
  export XRAY_DATABASE_DIR=/prjxray/database
  time python3 /nextpnr-xilinx/xilinx/python/bbaexport.py \
      --device "$PART" --bba "$CHIPDB/$DEVICE.bba"
  time bbasm -l "$CHIPDB/$DEVICE.bba" "$CHIPDB/$DEVICE.bin"
  ls -l "$CHIPDB/$DEVICE.bin"
else
  echo "=== 0/5 chipdb already present, reusing ==="
fi

echo "=== 1/5 yosys ==="
time yosys -p "read_verilog ps7_tern.v; synth_xilinx -flatten; write_json ps7_tern.json"

echo "=== 2/5 nextpnr-xilinx ==="
time nextpnr-xilinx --chipdb "$CHIPDB/$DEVICE.bin" --xdc ps7_tern.xdc \
     --json ps7_tern.json --fasm ps7_tern.fasm --seed 1

echo "=== 3/5 fasm2frames ==="
time fasm2frames --db-root "$DB" --part "$PART" ps7_tern.fasm ps7_tern.frames
echo "frames_lines=$(wc -l < ps7_tern.frames)"

echo "=== 4/5 xc7frames2bit ==="
time xc7frames2bit --part_file "$DB/$PART/part.yaml" --part_name "$PART" --frm_file ps7_tern.frames --output_file ps7_tern.bit

echo "=== 5/5 RESULT ==="
ls -l ps7_tern.bit
echo "size_bytes=$(stat -c %s ps7_tern.bit)"
sha256sum ps7_tern.bit ps7_tern.fasm ps7_tern.json ps7_tern.v ps7_tern.xdc
echo "=== done: $(date -u +%FT%TZ) ==="
