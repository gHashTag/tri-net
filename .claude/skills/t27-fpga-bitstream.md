---
name: t27-fpga-bitstream
description: Take a .t27 spec (or any Verilog) to a real bitstream and flash it on the ALINX AX7203 (Xilinx xc7a200t) with the fully open-source openXC7 flow on macOS arm64 — no Vivado, no Docker. Use when building/flashing an FPGA bitstream, setting up nextpnr-xilinx/prjxray, debugging P&R placement/routing errors, identifying which board is on a JTAG cable, or bringing a GF-T/BitNet datapath onto silicon.
---

# .t27 → bitstream → AX7203 (open-source, macOS arm64)

Proven end-to-end 2026-08-07: yosys → nextpnr-xilinx → prjxray → **valid .bit** for xc7a200tfbg484, timing-closed. Two working bitstreams shipped: `ax7203_firstlight.bit` (blinky, 188 MHz) and `ax7203_gft_compute.bit` (GF-T dot product, self-checking LED). NO Vivado, NO Docker.

## Toolchain (one-time install; ~30 min, 16 GB RAM is enough)
1. **OSS CAD Suite** (native darwin-arm64): download the `oss-cad-suite-darwin-arm64-*.tgz` from `YosysHQ/oss-cad-suite-build` releases, extract to `~/oss-cad-suite`, `source ~/oss-cad-suite/environment` (or add `~/oss-cad-suite/bin` to PATH). Gives **yosys** (`synth_xilinx`), **openFPGALoader** (has `alinx_ax7203` board), iverilog, gtkwave. **nextpnr in OSS CAD Suite only has gatemate/gowin uarch — NO Xilinx**, so build it:
2. **nextpnr-xilinx** (openXC7 fork): `brew install boost eigen`; `git clone --recursive https://github.com/openXC7/nextpnr-xilinx` (submodule `prjxray-db` includes `xc7a200tfbg484-*` — the AX7203 part). Build: `cmake -DARCH=xilinx -DUSE_OPENMP=OFF -DBUILD_PYTHON=OFF -DCMAKE_BUILD_TYPE=Release .` then `make -j8`. **⚠️ `-DUSE_OPENMP=OFF` is REQUIRED** — Apple clang rejects `-fopenmp`. Builds `nextpnr-xilinx` + `bbasm`.
3. **chipdb** for the part (heavy but ~2 min, no OOM on 16 GB thanks to `SERIALIZE_CHIPDB=ON`): `cd xilinx/python && python3 bbaexport.py --device xc7a200tfbg484-1 --bba xc7a200t.bba` (self-contained, only needs the prjxray-db data). Then `bbasm --le xc7a200t.bba xc7a200t.bin` (`.bba` ~939M → `.bin` ~318M; **`--le` endian is mandatory**, arm64 = little-endian).
4. **prjxray fasm→bit tools**: `git clone --recursive https://github.com/openXC7/prjxray`; `cd prjxray && mkdir build && cd build && cmake -DCMAKE_BUILD_TYPE=Release .. && make -j8 xc7frames2bit`. Python deps: `pip install fasm simplejson intervaltree antlr4-python3-runtime`.

## The flow (5 steps) — env: `PYTHONPATH=<prjxray>` (NOT prjxray/third_party/fasm → circular import)
```bash
yosys -q -p "read_verilog design.v gft_dot2.v; synth_xilinx -flatten -top top -family xc7; delete t:\$print; opt_clean; write_json d.json"
nextpnr-xilinx --chipdb xc7a200t.bin --xdc design.xdc --json d.json --fasm d.fasm
python3 <prjxray>/utils/fasm2frames.py --db-root <db>/artix7 --part xc7a200tfbg484-1 d.fasm d.frames
<prjxray>/build/tools/xc7frames2bit --part_name xc7a200tfbg484-1 --part_file <db>/artix7/xc7a200tfbg484-1/part.yaml --frm_file d.frames --output_file d.bit
openFPGALoader -c digilent_hs2 --ftdi-serial <AX7203_serial> d.bit   # SRAM, volatile
```
**Verify the .bit is real:** all of `d.fasm`/`d.frames`/`d.bit` must be non-empty AND consistent (a bogus 9.3M .bit appears if frames is 0-byte). Check the Xilinx sync word: `python3 -c "d=open('d.bit','rb').read();print(d.find(bytes.fromhex('aa995566')))"` (must be ~150, not -1). Part name is embedded (`strings d.bit | grep xc7a200t`).

## Gotchas (each cost real debugging — check here FIRST)
- `synth_xilinx` takes **`-family xc7`**, NOT `-part`.
- **`$display`/`$print` in gen-verilog** (test blocks, even under `` `ifndef SIMULATION ``) become `$print` cells nextpnr can't place → **`delete t:$print; opt_clean`** after synth.
- **Clock pin must be clock-capable** (MRCC/SRCC). Find valid pins in `<db>/artix7/<part>/package_pins.csv` (grep `MRCC`/`SRCC`). Non-clock-capable clk pin → "Unable to find legal placement for cell ...BUFG".
- **⭐ nextpnr-xilinx CANNOT place a CARRY4 whose FFs have a sync-RESET control set** → "Unable to find legal placement for cell ...carry4". This is THE big one. A free-running counter (`cnt<=cnt+1`, no reset) places fine (188 MHz w/ BUFG); adding `if(!rst) cnt<=0` breaks it. **Fixes:** (a) drop the reset on carry-chain FFs (first-light counter needs none); (b) `synth_xilinx -nocarry` (all adders→LUT, no CARRY4 → bug gone, but ~29 MHz max on deep logic → too slow for 200 MHz; ok for small/slow designs); (c) use one-hot/gray counters instead of binary. SA placer (`--placer sa`) gets past the placement but then hits routing/timing issues — not a reliable fix.
- **Differential clock** (AX7203 sys clk): instantiate `IBUFDS(.I(clk_p),.IB(clk_n),.O(clk))`, then yosys inserts BUFG. This works (isolation-tested 2840 MHz). Provide an `IBUFDS` behavioral stub for iverilog sim (`module IBUFDS(output O,input I,IB); assign O=I; endmodule`).
- **Latch warnings** from gen-verilog function-local temps (assigned on some paths only) are **cosmetic** — DCE'd away (final gft_dot2 = 798 cells, 123 CARRY4, 0 latches). Only a problem if a latched temp is read on an unassigned path. TODO codegen: default-init function locals.
- `fasm2frames` on Python 3.14: antlr fast parser fails to import (warning) but falls back to textx parser which WORKS (real 22M frames). A 0-byte frames means **nextpnr failed upstream**, not fasm.

## AX7203 board (part xc7a200t-fbg484-2; source: litex-boards platforms/alinx_ax7203.py)
- **Sys clock: DIFFERENTIAL 200 MHz** — P=`R4`, N=`T4`, `DIFF_SSTL15`. (R4 is IO_L13P_T2_MRCC_34, clock-capable.)
- **cpu_reset_n: `T6`** `LVCMOS15` (active-low).
- **User LEDs: `B13 C13 D14 D15`** `LVCMOS33`.
- **UART: TX=`N15` RX=`P20`** `LVCMOS33` (115200, onboard CP2102). Baud from 200 MHz: use a **reset-free phase accumulator** (`phase<=phase+INC`, tick=carry-out), INC16 = round(115200·16·2^24/200e6)=154619 — avoids the carry-reset bug (do NOT use a resettable oversample counter).

## JTAG identity — ALWAYS confirm before flashing (broken-ruler doctrine)
The fleet mixes AX7203 (xc7a200t) and Zynq-7020 boards. `openFPGALoader --detect` WITHOUT a serial auto-picks the first cable and may show the wrong board. **Always target `--ftdi-serial` explicitly and confirm the model:**
- **AX7203** = ft232H serial `210512180081`, `-c digilent_hs2` → `idcode 0x3636093, model xc7a200` (= xc7a200t 0x13636093, revision nibble dropped). Single-device chain.
- **Zynq-7020** = FT2232 serial `210203859289` → `0x4ba00477` (ARM DAP) + `0x03727093` (xc7z020). **Do NOT flash an Artix bitstream here.**
- The 3 AX7203 also expose CP2102N UART (Silicon Labs, serials `04f8…/6afc…/f29b…`). Ethernet: 3 USB adapters `en4/en5/en6` (point-to-point, isolated → no MAC collision); `inactive` until a networking bitstream is loaded.
- Flash is SRAM (volatile, reversible by power-cycle); `-f` writes SPI flash (persistent). Confirm `model xc7a200` before EACH flash.

## GF-T stack context (what runs on this silicon)
GF-T = ternary-native GoldenFloat (GF-T16 = `[sign:offset(7):mant(9)]`, value `(1+m/512)·2^(off−40)`, BIAS 40, +1.0=20480). A complete spec-first train+infer stack exists in `gHashTag/t27` (`specs/ternary/gft_*.t27`), all iverilog bit-exact: exp2 (≤1 ULP), log2, recip (exact), softmax (≤0.0017), argmax, classifier, NLL loss, softmax-gradient (`p−y`), SGD (`w−η·g`), relu. Demos (`tools/gft_*_demo.py`, bit-exact to the RTL) prove it LEARNS: loss↓ tracking float64, 100% held-out, 2-layer solves XOR. First silicon target = `gft_dot2` (combinational: a1·b1+a2·b2, synth-clean). See memory `fpga_fleet_physical_link.md`, `gf_t_ternary_format.md`, `t27_language.md`.

## Keep this skill updated (user standing request 2026-08-07)
Append new gotchas / measured numbers / part data / flash results here every time something is learned on hardware. This file is the living hardware-bring-up runbook.

## LOG — 2026-08-07: first successful flash
`ax7203_gft_compute.bit` → AX7203 SRAM via `openFPGALoader -c digilent_hs2 --ftdi-serial 210512180081`: **DONE=1, configured & running**. First GF-T compute on silicon. Warning "Unknown key Generator" is harmless. Confirms the whole flow works on real hardware.

## LED polarity: AX7203 user LEDs (B13/C13/D14/D15) are ACTIVE-LOW
Confirmed on hardware 2026-08-07: `ax7203_gft_compute.bit` drove led=1011 (led[0]=1=correct); observed OFF/OFF/ON/OFF — the EXACT active-low display of 1011. So drive a pin LOW to light a LED. For an intuitive "all LEDs on = pass" indicator: `assign led = correct ? 4'b0000 : 4'b1111;`.

## LOG — 2026-08-07: GF-T VISUALLY VERIFIED ON SILICON
`ax7203_gft_pass.bit` (all 4 LEDs ON iff correct, active-low) → AX7203: user confirmed ALL 4 LEDs lit = GF-T dot product correct on real hardware. Full spec→openXC7→bit→flash→silicon chain proven. This is the working end-state; return here as the reference "known-good on hardware".
