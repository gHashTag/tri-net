# The whole IGLA-Coder model on one chip -- honest budget

Scaling the verified single layer to the full arch (d=768, 12 layers, D_FF=2048,
vocab=32000):

- **~91M parameters** (well under the sub-1B ceiling). Ternary @2-bit = **23 MB**
  of weights -- fits the board's DDR (512 MB - 1 GB) with room to spare.
- Layers run **sequentially on one small tiled engine**, weights streamed from DDR
  per layer -- the whole model on ONE ~$50-160 Zynq-7020, not one engine per layer.

## Throughput -- memory-bound, on the REAL Zynq-7020 memory system

A dense LLM reads all its weights once per token, so batch-1 generation is
DDR-bandwidth bound, not compute bound. The binding number is the actual memory
system of an XC7Z020, not a theoretical peak:

- The PS DDR controller is **32-bit**, DDR3/DDR3L, and tops out at **DDR3-1066**
  on the -1 speed grade (DDR3-1333 only on the fastest -3 grade). Peak =
  32 bit x 1066 MT/s = **4.26 GB/s**; sustained streaming reads run ~70% of that
  (refresh + bank turnaround), ~3 GB/s.
- A PL accelerator reaches DDR through the **AXI HP (AFI) ports**: four 64-bit
  ports, ~1.2 GB/s each sustained, their sum bounded by the ~3 GB/s the DRAM
  actually delivers.

At **23 MB of ternary weights per token**:

| memory path (real xc7z020)                  | GB/s | tokens/sec |
|---------------------------------------------|------|------------|
| one AXI HP port                             | ~1.2 | **~52**    |
| all HP ports, sustained                     | ~3.0 | **~130**   |
| DRAM theoretical peak (-1, not sustainable) | 4.26 | ~185       |

So the honest figure is **~50-130 tok/s** on a real Zynq-7020 -- NOT the 565 an
earlier draft of this file quoted, which assumed a 12.8 GB/s DDR3-1600 x64 bus the
7020 does not have (its PS DDR is 32-bit and caps at DDR3-1066/-1333). 50-130 tok/s
is still ~10-25x a comfortable human reading pace, on a batch-1 edge node, not a
datacenter part.

## Why the radio still fits: 0 DSP by construction, not by timing slack

Compute is not the bottleneck, but the reason the radio coexists is NOT "idle
cycles waiting on DDR." It is that **every ternary weight-matmul is a sign-select,
so it uses zero DSP48 by construction** -- the multiply is replaced by `+x / -x /
0` in LUT fabric. A 16x16 ternary systolic array delivers ~16.5 GMAC/s
(~180 tok/s compute-bound) at **0 DSP**; the IGLA-spec 64x64 grid reaches
~2700 tok/s compute, still **0 DSP**. Whatever the array size, the entire
220-DSP48 column stays free -- so the AD9361 software radio (channel filters, NCO,
correlators) runs on the same die, concurrently, on the DSPs the AI never touches.
Ternary doesn't just shrink the model; it moves the model **off the DSP column
entirely**, which is what lets a radio share the chip.

## vs competitors

- **BitNet.cpp**: 100B params, server CPU, 5-7 tok/s. Cloud/desktop scale.
- **IGLA-Coder here**: ~91M coding model, one ~$100 Zynq-7020, **~50-130 tok/s**
  (real DDR-bound), **plus a software radio on the same die**, weight matmuls at
  0 DSP, fully open flow. A different niche: an autonomous edge node that both
  talks (radio) and thinks (a small coding/RF model), no GPU, no cloud.

phi^2 + 1/phi^2 = 3 | TRINITY
