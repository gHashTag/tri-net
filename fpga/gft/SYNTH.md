# GF-T multiplier — synthesis utilization (open-source, NO Vivado)

`gft_mul.v` **synthesizes** to Xilinx 7-series primitives (the family the AX7203
openXC7 flow targets), not merely simulates. Reproduce:

```bash
yosys fpga/gft/synth_gft_mul.ys   # yosys 0.65
```

## Baseline (GF-T16 defaults, spec-faithful u32 ports)

`yosys synth_xilinx -flatten; stat` on `gft_mul` (bias 40, offset_max 80,
mant_one 512):

| primitive | count |
|---|---|
| LUT (LUT2/3/5/6) | 161 |
| CARRY4 | 42 |
| DSP48E1 | 3 |
| INV | 42 |
| IBUF / OBUF | 128 / 64 |

The **3 DSP48E1** come from the significand product `(mant_one+ma)*(mant_one+mb)`
synthesized at the module's u32 port width — a 32×32 multiply. The mantissa
divisions are by constant powers of two (`/512`, `/1024`) and map to shifts (no
divider). CARRY4s are the add/compare chains (offset add, de-bias, saturate).

## Field-width-narrowed (`gft16_mul`, done)

For GF-T16 the operands are tiny — offset ≤ 80 (7 bits), mantissa field ≤ 511
(9 bits). `gft16_mul.v` is a thin wrapper that presents those narrow ports and
zero-extends into `gft_mul`; synthesis then constant-propagates the upper bits
away, collapsing the 32×32 significand product to a 10×10 one. No logic is
duplicated — the arithmetic stays in the spec-faithful `gft_mul`.

```bash
yosys fpga/gft/synth_gft16_mul.ys
```

| primitive | baseline (u32) | narrowed (`gft16_mul`) |
|---|---|---|
| DSP48E1 | 3 | **1** |
| CARRY4  | 42 | **18** |
| LUT     | 161 | **47** |

Same known-answer results (`gft16_mul_kat_tb.v`, iverilog): `(41,0)²→(42,0)`,
`(41,256)²→(43,64)` — matching the over-wire verifier. So one GF-T16 multiply is
a single DSP48E1 + ~47 LUTs: hundreds fit on an xc7a200t (AX7203).

## Next step

`nextpnr-xilinx` place-and-route + timing on the real xc7a200t part (needs the
`regymm/openxc7` container or hardware), then flash the AX7203 for the first
on-silicon GF-T recompute — the one boundary `docs/VERIFIABLE_COMPUTE.md` §4
still marks "none".

## GF-T ALU: add (`gft_add`)

`gft_add.v` realizes `specs/tri_gft_add.t27` (same-sign add: align by the offset
difference, add significands, one-carry renorm). `yosys synth_xilinx` (GF-T16,
u32 ports): ~483 LUT + 45 CARRY4, **0 DSP48E1** (shifts + adders only), clean
synth. KAT (`gft_add_kat_tb.v`, iverilog) matches the over-wire verifier:
`(40,0)+(40,0)→(41,0)`, `(40,0)+(39,0)→(40,256)`, GF-T8 `(13,0)+(12,0)→(13,8)`.

```bash
iverilog -g2012 -o /tmp/k.vvp fpga/gft/gft_add.v fpga/gft/gft_add_kat_tb.v && vvp /tmp/k.vvp
yosys fpga/gft/synth_gft_add.ys
```

Subtract (`gft_sub`, variable leading-zero renorm) is the remaining ALU op, then
a narrowed GF-T16 ALU wrapper mirrors the `gft16_mul` DSP win.

## GF-T ALU: subtract (`gft_sub`) -- ALU complete

`gft_sub.v` realizes `specs/tri_gft_sub.t27` (different-sign = magnitude
difference: order by magnitude, form the full-precision aligned difference,
renormalize by the leading set bit `hi_bit`). `yosys synth_xilinx` (GF-T16, u32):
~946 LUT + 79 CARRY4, **0 DSP48E1** (leading-zero encoder + barrel shifters),
clean synth. KAT (`gft_sub_kat_tb.v`, iverilog) matches the over-wire verifier:
`(41,0)-(40,0)→(40,0)`, `(41,256)-(40,0)→(41,0)`, GF-T8 `(13,8)-(12,0)→(13,0)`,
GF-T4 `(5,0)-(4,0)→(4,0)`.

With `gft_mul` + `gft_add` + `gft_sub`, the **full GF-T ALU (mul/add/sub) exists
as synthesizable, KAT-verified RTL** — the same three ops the over-wire ring
proves, now on silicon. Remaining: a narrowed ALU wrapper (area) and
`nextpnr-xilinx` place-and-route + timing on the real xc7a200t (AX7203).

## GF-T ALU top + on-chip self-check (`gft_alu`, `gft_alu_selfcheck`)

`gft_alu.v` muxes `gft_mul` / `gft_add` / `gft_sub` by `op` (0=add, 1=mul, 2=sub).
`gft_alu_selfcheck.v` is the **flashable proof**: a clocked FSM walks a ROM of the
over-wire known-answer vectors through the ALU and drives `pass`/`fail` (LEDs) —
`pass` asserts iff every GF-T16 mul/add/sub vector matched on-chip.

- iverilog sim: `SELFCHECK PASS: gft_alu mul/add/sub all vectors matched on-chip`.
- `yosys synth_xilinx` (synth_gft_alu.ys, top = self-check): ~634 LUT + 114 CARRY4
  + 3 DSP48E1 + 6 FF, clean synth — a self-contained design ready for
  `nextpnr-xilinx` + AX7203 flash.

```bash
yosys fpga/gft/synth_gft_alu.ys
```

Flash this to the AX7203 (openXC7 place-and-route) and the `pass` LED is the first
GF-T recompute confirmed on real silicon.
