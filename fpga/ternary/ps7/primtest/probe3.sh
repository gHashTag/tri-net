#!/bin/bash
source /prjxray/env/bin/activate 2>/dev/null || true
cd /work
PART=xc7z020clg400-1
DB=/nextpnr-xilinx/xilinx/external/prjxray-db/zynq7
echo "=== A: fasm2frames on the MMCM fasm, fresh process ==="
fasm2frames --db-root "$DB" --part "$PART" prim_mmcm.fasm /tmp/m.frames 2>&1 | tail -4
echo "rc=$?"
echo "=== B: same command again ==="
fasm2frames --db-root "$DB" --part "$PART" prim_mmcm.fasm /tmp/m2.frames 2>&1 | tail -3
echo "=== C: control -- the IBUFDS fasm through the same binary ==="
fasm2frames --db-root "$DB" --part "$PART" prim_ibufds.fasm /tmp/i.frames 2>&1 | tail -2
echo "  ibufds rc=$? size=$(stat -c %s /tmp/i.frames 2>/dev/null)"
echo "=== D: what MMCM features does the fasm actually ask for? ==="
grep -oE "^[A-Z0-9_]+_X[0-9]+Y[0-9]+" prim_mmcm.fasm | sort -u | head -8
grep -icE "mmcm|pll|cmt" prim_mmcm.fasm
