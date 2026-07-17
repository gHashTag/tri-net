# Attention DSP budget: what the non-ternary products cost

Attention's Q.K^T and weights.V are activation x activation (int8 x int8) -- they
cannot be ternary (measured: ternarising them drops cosine similarity to
0.69-0.83, see ../softmax). So they need real multipliers. This measures how
many, against the ternary parts' zero.

`int8_dot.v` -- a K-wide signed int8 x int8 dot, the QK^T / AV primitive.

## Measured (yosys synth_xilinx, xc7z020)

| primitive             | DSP48E1 | note                        |
|-----------------------|---------|-----------------------------|
| int8_dot  K=8         | 8       | 1 DSP per int8 multiply     |
| int8_dot  K=32        | 32      | fully parallel              |
| int8_dot  K=64        | 64      | fully parallel              |
| **tern_dot27 K=32**   | **0**   | ternary = sign-select, LUTs |

A fully-parallel int8 dot costs one DSP per lane; the ternary dot costs zero.

## The head budget

Because the Q/K/V/O projections, the FFN, and softmax are all ternary/0-DSP,
**the entire 220-DSP column of the xc7z020 is free for attention's int8
products.** With a modest time-multiplexed int8 dot engine (say 16 lanes for
Q.K^T and 16 for A.V), one attention head costs ~32 DSP, so **~6 heads fit in
220 DSP** -- and if the head engines are shared/narrower, more. Crucially that
still leaves ~150 DSP for the radio front-end (channel filters, an int8 mixer).

The whole point of the ternary approach lands here: ternary makes the
weight-heavy compute (projections + FFN, ~90% of a layer) cost zero DSP, which is
exactly what frees the DSP column so attention AND the radio share one $-cheap
chip. This is the resource story that ties the AI and radio halves together.

## The assembled attention head (capstone)

A single self-attention head (T=8, d=8) composed from the verified blocks, with
hardware-exact fixed point end to end:

| stage                       | arithmetic              | DSP |
|-----------------------------|-------------------------|-----|
| Q,K,V = X . {Wq,Wk,Wv}      | ternary weight x int8   | 0   |
| scores = Q . K^T (scaled)   | int8 x int8             | yes |
| weights = softmax(scores)   | exp ROM + integer divide| 0   |
| attn = weights . V          | Q16 x int8              | yes |
| out = attn . Wo             | ternary weight x int8   | 0   |

The head produces a real attention distribution (row 0 softmax
`[9700,0,0,0,11,55824,...]/65536` -- attends mostly to token 5), not a degenerate
one-hot. Crucially the 0-DSP hardware blocks are verified against the real
pipeline: **`tern_softmax` fed the actual Q.K^T scores reproduces the softmax
stage BIT-EXACT** (`[9700,0,0,0,11,55824,0,0]`). The DSP-bearing stages (Q.K^T,
weights.V) are the two int8 products measured in this dir (~1 DSP/lane).

With the FFN sublayer (../ffn), this assembles an entire IGLA-Coder transformer
layer's compute from the verified ternary blocks: projections + FFN at 0 DSP,
attention's two data-dependent products on a small int8 array, and all the freed
DSPs available for the radio. That is the whole thesis, standing.
