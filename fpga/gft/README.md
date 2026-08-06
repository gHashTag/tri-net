# GF-T ladder multiplier — silicon realization

`gft_mul.v` is the synthesizable GF-T (GoldenFloat-ternary, balanced-ternary
exponent) multiplier. It realizes `specs/tri_gft_arith.t27`'s
`gft_mul_offset_full_p` + `gft_mul_mant_p` + `gft_mul_mant_carry_p` — the **same
spec** the over-wire verifier runs (`trinet_compute_over_mesh`,
`trinet_rung_verify`). One `.t27` therefore drives **both** the A2A network
verifier (Rust) **and** the FPGA compute unit (Verilog).

SSOT is the `.t27`; this `.v` is the verified realization, exactly as
`fpga/gf16/gf16_mul.v` is the realization of `t27/specs/numeric/gf16.t27`.

## Parametric per rung

`gft_mul #(.BIAS, .OFFSET_MAX, .MANT_ONE)` — GF-T16 defaults `(40, 80, 512)`;
GF-T8 `(13, 26, 16)`; GF-T4 `(4, 8, 2)`. Combinational.

## Verified (open-source, NO Vivado)

`iverilog` known-answer sweep (`gft_mul_kat_tb.v`) — the expected values are the
**exact** results the over-wire verifier accepts:

| rung | operands | result |
|---|---|---|
| GF-T16 φ¹·φ¹=φ² | (41,0)·(41,0)     | (42, 0)  |
| GF-T16 1.5·1.5  | (41,256)·(41,256) | (43, 64) |
| GF-T8  1.5·1.5  | (13,8)·(13,8)     | (14, 2)  |
| GF-T4  1.5·1.5  | (4,1)·(4,1)       | (5, 0)   |

```bash
iverilog -g2012 -o /tmp/kat.vvp fpga/gft/gft_mul.v fpga/gft/gft_mul_kat_tb.v && vvp /tmp/kat.vvp
# -> KAT PASS: gft_mul matches the over-wire verifier on all rungs
```

## Why hand-transcribed (not `t27c gen-verilog`)

`t27c gen-verilog specs/tri_gft_arith.t27` currently emits **illegal Verilog**:
it interleaves `reg` declarations with statements inside `begin/end` blocks
(e.g. `reg carry; carry=…; reg sum; sum=…`), which iverilog and standard
synthesis reject (declarations must precede statements in a block). Tracked
upstream in the `t27` repo. `gft_mul.v` keeps the emitter's exact arithmetic with
legal declaration ordering, gated by the KAT sweep above so fidelity is
machine-checked.

## Next step toward silicon

Drive `gft_mul` from the AX7203 openXC7 flow used for the ternary blocks
(`fpga/ternary/ps7/build/run_openxc7.sh`, `ps7_tern.xdc`; yosys + nextpnr, the
same flow that produced the proven blinky bitstream) to get the **first GF-T
recompute on real silicon** — the one boundary section 4 of
`docs/VERIFIABLE_COMPUTE.md` still marks "none".

## Board integration (ALINX AX7203 = XC7A200T-FBG484-2)

`gft_alu_ax7203.v` is the board top: it buffers the 200 MHz differential board
clock (DIFF_SSTL15, `clk_p` on R4) through an `IBUFDS` and drives `led[0]=pass`,
`led[1]=fail` from `gft_alu_selfcheck`.

- iverilog (`-DSIM`, behavioral clock buffer): `AX7203 SELFCHECK PASS: led[0]=pass lit`.
- `yosys fpga/gft/synth_gft_alu_ax7203.ys` (real IBUFDS): clean synth — 1 IBUFDS +
  4 OBUF + 3 DSP48E1 + 114 CARRY4 + ~584 LUT + 6 FF, a board-ready netlist.

`gft_alu_ax7203.xdc` asserts the **authoritative** clock pin (R4, DIFF_SSTL15,
200 MHz) documented in `docs/issues-archive/.../p0-ax7203-flash.md`. The LED / reset
package pins are left as commented placeholders — fill them from the board's proven
XDC / ALINX schematic rather than guessing. Then `nextpnr-xilinx` (openXC7) →
bitstream → flash over AL321/OpenOCD (IDCODE `0x13636093`): `led[0]` lit is the
first GF-T recompute confirmed on real silicon.

## Run it on silicon

See [RUN_ON_SILICON.md](RUN_ON_SILICON.md) for the end-to-end recipe: local verify (all KATs + synth) -> fill board pins -> openXC7 place-and-route -> AL321 flash.
