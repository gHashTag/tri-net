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

## Next optimization

For GF-T16 the operands are tiny — offset ≤ 80 (7 bits), mantissa field ≤ 511
(9 bits) — so the significand product is a 10×10 multiply that fits **one**
DSP48E1 (or LUTs). Narrowing the ports to the actual rung field widths (while
keeping the spec's u32 semantics internally) drops the DSP/LUT footprint
substantially. Tracked as the next silicon-prep step, ahead of nextpnr-xilinx
place-and-route + timing on the real xc7a200t (AX7203) part.
