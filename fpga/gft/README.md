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

## On silicon (DONE — bit-exact on the AX7203)

GF-T now runs on real silicon across the whole ladder. Each engine wraps a compute core
in the silicon-proven UART skeleton (`gft_mul_ax7203`'s RX/TX, reused verbatim); the host
sends operands and reads the result over UART @160000. Flashed via openXC7
(`nextpnr-xilinx`) + passwordless `openocd` (AL321 JTAG, SRAM `pld load`). See
`docs/VERIFIABLE_COMPUTE.md` for the measured vectors.

| engine | core | rung / op | UART frame | verified |
|--------|------|-----------|------------|----------|
| `gft_mul8_ax7203`  | `gft_mul8_seq`  | GF-T8 (compact rung)   | `AA 55 [a][b][cmd] → A5 [lo hi] 00` | 3/3 |
| `gft_mul_ax7203`   | `gft_mul_seq`   | GF-T16 multiply        | `AA 55 [a][b][cmd] → A5 [lo hi] 00` | 5/5 |
| `gft_dot2_ax7203`  | `gft_dot2_seq`  | GF-T16 2-term dot      | 4 operands → `A5 [lo hi] 00`        | 3/3 |
| `gft_macc_ax7203`  | `gft_macc_stream` | GF-T16 streaming row (any length) | per-term `[a][b][ctrl]`, emit on last | 4/4 |
| `gft_dot4_ax7203`  | `gft_dot4_stream` (`gft_dot4_tile`) | GF-T16 4-lane parallel | 8 operands → `A5 [lo hi] 00` | 3/3 |
| `gft_mul32_ax7203` | `gft_mul32_stream` | **GF-T32** top rung (range ~2^728) | 35-bit operands, 8-byte reply | 4/4 |

Operands/results are packed GF-T magnitudes; GF-T16 = `(offset<<9)|mant`, GF-T32 carries the
25-bit mantissa in 4 bytes. `gft_mul32.v` uses a 64-bit datapath (the 32-bit `gft_mul.v` silently
overflows at the top rung — see `tests/gft32_challenge.rs`). The prior "none" in
`docs/VERIFIABLE_COMPUTE.md` §4 is CLOSED.

**Flash-ops notes:** always background `openocd` (a 100 kHz SRAM load is ~778 s); route with a
wide seed sweep (the bigger tops hit the intermittent nextpnr `A5FF` placer bug on many seeds —
`gft_mul32` needed seed 14) and beware a `--timing-allow-fail` route that is functionally dead on
silicon (validate the top with `gft_dot4_ax7203_tb.v`-style full-UART sim before trusting a seed).

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

## Auto path: `t27c gen-verilog` matches the over-wire verifier

Since the `t27c gen-verilog` interleaved-reg defect was fixed, the GF-T arithmetic
compiles straight from the spec, and its functions match the over-wire verifier's
exact values (`gft_arith_gen_kat_tb.v`):

```bash
t27c gen-verilog specs/tri_gft_arith.t27 > /tmp/gftgen.v
iverilog -g2012 -o /tmp/k.vvp /tmp/gftgen.v fpga/gft/gft_arith_gen_kat_tb.v && vvp /tmp/k.vvp
# -> GEN-VERILOG KAT PASS: generated GF-T Verilog matches the over-wire verifier
```

So one `.t27` generates BOTH the Rust A2A verifier and synthesizable Verilog, and
they provably agree -- the spec-first thesis, end to end. Add and subtract too -- `gft_add_gen_kat_tb.v`
(`t27c gen-verilog specs/tri_gft_add.t27`) and `gft_sub_gen_kat_tb.v`
(`specs/tri_gft_sub.t27`) KAT the generated TriGftAdd/TriGftSub against the same
over-wire values, so the whole GF-T ALU (mul/add/sub) is auto-proven from spec.
(`gft_mul.v` remains the
hand-shaped I/O datapath; the generated module is a function library, KAT-gated here.)
