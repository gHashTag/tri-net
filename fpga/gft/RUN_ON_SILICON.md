# Run the GF-T ALU on real silicon (ALINX AX7203)

The `fpga/gft/` package is a full GF-T ALU (mul/add/sub) realized from the same
`.t27` specs the over-wire verifier runs, plus a self-checking board top for the
ALINX AX7203 (XC7A200T-FBG484-2). Flashing it and seeing `led[0]` (pass) is the
first GF-T recompute confirmed on real silicon.

## 0. Verify the package is silicon-ready (local, no board)

Every KAT is checked against the exact values the over-wire verifier accepts, and
every module is synthesized. Run from the repo root:

```bash
G=fpga/gft
# --- known-answer tests (iverilog) ---
iverilog -g2012 -o /tmp/mul.vvp   $G/gft_mul.v $G/gft_mul_kat_tb.v            && vvp /tmp/mul.vvp   # KAT PASS
iverilog -g2012 -o /tmp/mul16.vvp $G/gft_mul.v $G/gft16_mul.v $G/gft16_mul_kat_tb.v && vvp /tmp/mul16.vvp # KAT PASS
iverilog -g2012 -o /tmp/add.vvp   $G/gft_add.v $G/gft_add_kat_tb.v            && vvp /tmp/add.vvp   # KAT PASS
iverilog -g2012 -o /tmp/sub.vvp   $G/gft_sub.v $G/gft_sub_kat_tb.v            && vvp /tmp/sub.vvp   # KAT PASS
ALU="$G/gft_mul.v $G/gft_add.v $G/gft_sub.v $G/gft_alu.v $G/gft_alu_selfcheck.v $G/gft_alu_selfcheck_disc_tb.v"
iverilog -g2012 -o /tmp/gold.vvp $ALU && vvp /tmp/gold.vvp                                 # GOLDEN PASS
iverilog -g2012 -DGFT_SELFCHECK_FAULT -o /tmp/disc.vvp $ALU && vvp /tmp/disc.vvp           # DISCRIMINATION PASS
# --- synthesis (yosys) ---
for s in synth_gft_mul synth_gft16_mul synth_gft_add synth_gft_sub synth_gft_alu synth_gft_alu_ax7203; do yosys $G/$s.ys; done
```

All KATs print `PASS`; all syntheses complete with 0 errors.

## 1. Fill the board pins

Edit `gft_alu_ax7203.xdc`: uncomment and set the `led[*]` and `rst_n` `PACKAGE_PIN`s
from the board's proven XDC / ALINX AX7203 schematic (the clock, `clk_p` = R4
DIFF_SSTL15, is already asserted; `clk_n` is R4's differential mate -- verify it).

## 2. Synthesis + place-and-route (openXC7, NO Vivado)

Inside the `regymm/openxc7` container (same flow as `fpga/ternary/ps7/build/run_openxc7.sh`):

```bash
PART=xc7a200tfbg484-2 ; DEVICE=xc7a200t
yosys -p "synth_xilinx -flatten -top gft_alu_ax7203 -json gft.json" \
  fpga/gft/gft_mul.v fpga/gft/gft_add.v fpga/gft/gft_sub.v \
  fpga/gft/gft_alu.v fpga/gft/gft_alu_selfcheck.v fpga/gft/gft_alu_ax7203.v
python3 /nextpnr-xilinx/xilinx/python/bbaexport.py --device "$PART" --bba "$DEVICE.bba"
bbasm --l "$DEVICE.bba" "$DEVICE.bin"
nextpnr-xilinx --chipdb "$DEVICE.bin" --xdc fpga/gft/gft_alu_ax7203.xdc \
  --json gft.json --fasm gft.fasm
fasm2frames --part "$PART" gft.fasm gft.frames
xc7frames2bit --part_name "$PART" --frm_file gft.frames --output_file gft_alu_ax7203.bit
```

## 3. Flash over AL321 / OpenOCD

The proven path (per `docs/issues-archive/.../p0-ax7203-flash.md`): AL321 (FT2232H)
USB-JTAG, OpenOCD, IDCODE `0x13636093`.

```bash
openocd -f ax7203_al321.cfg -c "init; pld load 0 gft_alu_ax7203.bit; exit"
```

`led[0]` lit = GF-T mul/add/sub verified on-chip; `led[1]` lit = a mismatch (the
self-check provably catches a wrong answer -- see `SYNTH.md`). This closes the one
boundary `docs/VERIFIABLE_COMPUTE.md` §4 marks "none": GF-T recompute on real silicon.
