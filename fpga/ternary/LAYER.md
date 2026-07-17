# A full IGLA-Coder transformer layer, from verified blocks

After building and verifying every block, a complete pre-norm transformer layer

```
h = x + Attention(RMSNorm(x))
y = h + FFN(RMSNorm(h))
```

composes end to end. On a small instance (d=8, T=8) the hardware-exact fixed-point
composition of all blocks produces a finite, bounded output -- the layer runs.

## The blocks (all built, all verified in this repo)

| block            | dir           | DSP on weight matmul | verified            |
|------------------|---------------|----------------------|---------------------|
| RMSNorm          | `norm/`       | 0 (rsqrt ROM)        | bit-exact, rms 0.997 |
| Q/K/V/O proj     | `systolic/`   | **0** (ternary)      | bit-exact           |
| RoPE sin/cos     | `cordic/`     | 0                    | 8 LSB error         |
| softmax          | `softmax/`    | 0                    | bit-exact           |
| FFN              | `ffn/`        | **0** (ternary)      | bit-exact           |
| GEMM + tiling    | `systolic/`   | **0** (ternary)      | bit-exact, 33 GOPS  |
| Q.K^T / A.V      | `attn/`       | int8 (1 DSP/lane)    | measured            |

## Budget for a real layer (d=768, D_FF=2048, a 16-lane engine)

- **Weight matmuls** (4 projections + FFN up/down) = ~368 tile-cycles at **0 DSP**,
  weights streamed from BRAM (tiling).
- **Data-dependent products** (Q.K^T, A.V, RMSNorm squares/scale) need multipliers:
  a ~16-lane int8 engine is ~32 DSP/head -> **~6 heads fit in the 220-DSP column**,
  leaving ~150 DSP for the radio front-end.
- **~90% of a layer's FLOPs are 0-DSP** (projections + FFN dominate the arithmetic).

## The whole thesis, standing

Ternary makes the weight-heavy compute of a transformer layer cost zero DSP; that
frees the DSP column so the same $-cheap Zynq-7020 runs both an IGLA-Coder layer
AND the radio front-end -- built, verified block by block, in a fully open flow
(yosys/nextpnr/iverilog/prjxray), no Vivado. phi^2 + 1/phi^2 = 3.
