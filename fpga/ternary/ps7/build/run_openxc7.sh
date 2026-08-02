#!/bin/bash
# Phase A: reproduce $DESIGN.bit through the fully open flow (no Vivado).
# Runs INSIDE regymm/openxc7. Every step logged with timing and hashes.
set -euo pipefail
source /prjxray/env/bin/activate 2>/dev/null || true
cd /work
DESIGN="${1:-ps7_tern}"   # $DESIGN or ps7_probe
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
SRC="$DESIGN.v"
[ "$DESIGN" = "ps7_corr" ] && SRC="tern_corr8.v tern_corr8_stream.v ps7_corr.v"
time yosys -p "read_verilog $SRC; synth_xilinx -top $DESIGN -flatten; write_json $DESIGN.json"

echo "=== 2/5 nextpnr-xilinx ==="
time nextpnr-xilinx --chipdb "$CHIPDB/$DEVICE.bin" --xdc $DESIGN.xdc \
     --json $DESIGN.json --fasm $DESIGN.fasm --seed 1

echo "=== 3/5 fasm2frames ==="
time fasm2frames --db-root "$DB" --part "$PART" $DESIGN.fasm $DESIGN.frames
echo "frames_lines=$(wc -l < $DESIGN.frames)"

echo "=== 4/5 xc7frames2bit ==="
time xc7frames2bit --part_file "$DB/$PART/part.yaml" --part_name "$PART" --frm_file $DESIGN.frames --output_file $DESIGN.bit

echo "=== 5/5 RESULT ==="
ls -l $DESIGN.bit
echo "size_bytes=$(stat -c %s $DESIGN.bit)"
sha256sum $DESIGN.bit $DESIGN.fasm $DESIGN.json $DESIGN.v $DESIGN.xdc
echo "=== done: $(date -u +%FT%TZ) ==="
