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
