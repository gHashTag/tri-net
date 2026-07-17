# Fixed-point softmax (0 DSP) -- the last non-MAC piece of attention

`tern_softmax.v` computes `p_i = exp(x_i - max) / sum_j exp(x_j - max)` with no
multiplier: exp is a 128-entry ROM, the normalisation is an integer divide (LUT-
mapped). Logits are Q2, the exp table Q16, outputs Q16 probabilities summing to
~65536. This is the piece attention needs beyond GEMM and RoPE: attention scores
-> tern_softmax -> weights, then weights . V via the systolic array.

## Verified (iverilog)

8 spread logits vs numpy softmax:

```
hw  probs: 0.086 0.001 0.633 0.012 0.000 0.233 0.004 0.032
ref probs: 0.086 0.001 0.633 0.012 0.000 0.233 0.004 0.032
sum = 1.000   max abs error = 0.0000
```

The Q2/Q16 fixed point + 0.25-step exp LUT reproduce float softmax to within
rounding.

## Synthesised (yosys, xc7z020)

**0 DSP48** -- exp is a ROM, the divide maps to LUTs. Honest cost: ~28k LUT for
N=8, because it instantiates 8 parallel *combinational* dividers. That is
LUT-hungry (~half the xc7z020); a sequential or shared shift-subtract divider,
or a reciprocal-of-sum computed once, cuts it by roughly Nx. The 0-DSP property
holds either way; the area is a divider-architecture choice, deferred.

SSOT: t27/specs/igla/coder/arch.t27. With FFN (../ffn), GEMM (../systolic) and
CORDIC (../cordic), softmax is the final block of an IGLA-Coder attention layer.
