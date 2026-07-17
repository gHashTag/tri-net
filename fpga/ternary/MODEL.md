# The whole IGLA-Coder model on one chip -- honest budget

Scaling the verified single layer to the full arch (d=768, 12 layers, D_FF=2048,
vocab=32000):

- **~91M parameters** (well under the sub-1B ceiling). Ternary @2-bit = **23 MB**
  of weights -- fits the board's DDR (512 MB - 1 GB) with room to spare.
- Layers run **sequentially on one small tiled engine**, weights streamed from DDR
  per layer -- the whole model on ONE ~$50-160 Zynq-7020, not one engine per layer.

## Throughput -- memory-bound, honestly

A dense LLM reads all its weights once per token, so inference is DDR-bandwidth
bound, not compute bound:

| bound                                   | tokens/sec |
|-----------------------------------------|------------|
| compute ceiling (0-DSP matmuls, 16-lane@37MHz) | ~6900 |
| **DDR3 ~4 GB/s (Zynq-7020)**            | **~177**   |
| DDR3-1600 x32 ~12.8 GB/s                | ~565       |

So the real number is **~170-565 tok/s** depending on DDR -- still **30-90x human
reading speed** (BitNet.cpp quotes 5-7 tok/s for its 100B model as "reading
speed").

## The strategic point

The 0-DSP compute has **huge headroom over the DDR wall** (6900 vs 177). That gap
is not waste -- it is the whole design: the model spends most cycles *waiting on
DDR*, so the freed compute and the ~150 idle DSP48 **run the radio front-end on
the same chip, concurrently**. Ternary doesn't just shrink the model; it makes the
model cheap enough (in DSP) that a software radio fits beside it.

## vs competitors

- **BitNet.cpp**: 100B params, server CPU, 5-7 tok/s. Cloud/desktop scale.
- **IGLA-Coder here**: ~91M coding model, one ~$100 Zynq-7020, ~170-565 tok/s,
  **plus a software radio on the same die**, weight matmuls at 0 DSP, fully open
  flow. A different niche: an autonomous edge node that both talks (radio) and
  thinks (a small coding/RF model), no GPU, no cloud.

phi^2 + 1/phi^2 = 3 | TRINITY
