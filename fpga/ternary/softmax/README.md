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

## Sequential variant + the honest attention-DSP finding

`tern_softmax_seq.v` shares ONE divider over N cycles instead of N parallel ones:
bit-exact (max err 0.0000), **14433 LUT vs ~28488 (2x smaller), 0 DSP**, N-cycle
latency. The single 32-bit divider still dominates; a narrower reciprocal-of-sum
would shrink it further.

**Where the 0-DSP story ends (important):** a transformer's *weight* matmuls --
the Q/K/V/O projections and the FFN -- are ternary-weight x int8-activation, so
they are multiplier-free (0 DSP), and they are the large majority of a layer's
FLOPs and ~all its parameters. But attention's two *data-dependent* products,
`scores = Q . K^T` and `out = weights . V`, are activation x activation (and
weights are softmax probabilities), NOT ternary weights -- so they need real
multipliers (a few DSPs) or activation quantisation. So "0 DSP everywhere" is
precise for the weight-heavy compute (projections + FFN); attention's QK^T / AV
are the small, data-dependent exception. This is inherent to attention, not a
gap in the design -- BitNet-class models likewise keep those products in int8.

## Bit-serial divider + the ternary-attention verdict

`tern_softmax_bitser.v` normalises with ONE bit-serial restoring divider (one
subtract, 32 cycles/quotient, shared over N): bit-exact (max err 0.0000),
**3918 LUT vs 28488 comb / 14433 seq (~7x smaller than combinational), 0 DSP**,
~N*32 = 258-cycle latency. The divider is now a handful of registers; the
remaining LUTs are the exp ROM + FSM.

**Is fully-0-DSP attention viable? Measured: no.** Numpy check (T=16, d=32, 20
trials): quantising Q,K to ternary AND the softmax weights to ternary gives
cosine similarity **0.69** to the fp attention output; ternary Q,K only (fp
softmax weights for AV) gives **0.825**. Both are large degradations. So
attention's Q.K^T and weights.V genuinely need int8/higher precision (a few DSPs)
-- ternarising them is too lossy, which is exactly why BitNet-class models keep
them int8. The 0-DSP boundary (projections + FFN ternary, attention products not)
is real, not removable by quantisation.
