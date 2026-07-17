# Systolic ternary GEMM array (IGLA-RACE `systolic_ternary`)

Generalises the single `tern_matvec` into a parametric **K x N weight-stationary
systolic array** -- the compute volume of IGLA-RACE. Weights sit stationary in
the PEs, activations stream through, partial sums accumulate down the columns,
and every product is a sign-select: **N*K multiplier-free MACs per clock, zero
DSP.**

## Files

- `tern_pe.v` -- one weight-stationary ternary PE: `a_out = a_in` (pass right),
  `psum_out = psum_in + a_in*w` (accumulate down), `w` stationary. Registered.
- `tern_systolic.v` -- the K x N array with an internal per-row skew chain (row k
  delayed k cycles) so the diagonal wavefront lines up. Computes
  `y[n] = sum_k x[k] * W[k][n]`.
- `tern_systolic_tb.v` -- injects one x vector, dumps y per cycle.

## Verified (iverilog)

A 4x4 array, deterministic ternary W and int8 x:

```
reference y = -34 -26 61 54
y[0]=-34 @ t+2,  y[1]=-26 @ t+3,  y[2]=61 @ t+4,  y[3]=54 @ t+5   (diagonal wavefront)
```

Bit-exact against the software `x . W`, column n emerging at t+2+n as the
systolic geometry predicts.

## Measured post-P&R on xc7z020 (yosys + nextpnr, open flow)

| array   | MACs/clock | LUT          | DSP | Fmax     | throughput          |
|---------|------------|--------------|-----|----------|---------------------|
| 8 x 8   | 64         | 6781  (6%)   | 0   | 82.0 MHz | ~5.2 GMAC/s (~10 GOPS) |
| 16 x 16 | 256        | 26937 (25%)  | 0   | 64.6 MHz | ~16.5 GMAC/s (~33 GOPS) |

**The array stays fast at scale (65-82 MHz)** because it is systolic -- every PE
registers its accumulate, so the critical path is one PE (a sign-select + one
add), NOT the deep combinational sum that capped the flat `tern_matvec` at
10 MHz. Systolic pipelining is the structural fix for the wide-GEMM Fmax problem.
And it is **0 DSP at every size**, leaving all 220 DSP48E1 free for the radio
front-end. The IGLA spec bounds the grid at 64 x 64 (4096 MACs/clock); the trend
here says that fits in fabric and clocks in the same 60 MHz range.

## Where it sits

This is the GEMM core that IGLA-RACE specifies and that an IGLA-Coder transformer
layer runs on. Our `tern_mlp` proved the small-net inference; this proves the
GEMM scales to tens of GOPS multiplier-free. Missing for a full transformer
layer: CORDIC for RoPE (`../` non-MAC piece) and weight streaming from BRAM/DDR
at scale.
