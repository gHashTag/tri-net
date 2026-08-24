# GF-T synthesis results (measured, open-source yosys)

Every unit below was run through `yosys synth_xilinx` (7-series primitives, the front half of
the AX7203 openXC7 flow) on **Yosys 0.65**. These are the actual `stat` cell counts, not
estimates. Reproduce any row from the repo root, e.g.:

```bash
yosys fpga/gft/synth_gft16_mul.ys
```

## Utilization (local cells, standalone top)

| unit | .ys | DSP48E1 | LUTs (LUT1–6) | CARRY4 | synth |
|------|-----|--------:|--------------:|-------:|:-----:|
| `gft16_mul`     | `synth_gft16_mul.ys`     |  1 |   47 |  18 | clean |
| `gft_add`       | `synth_gft_add.ys`       |  0 |  483 |  45 | clean |
| `gft_sub`       | `synth_gft_sub.ys`       |  0 |  946 |  79 | clean |
| `gft_alu`       | `synth_gft_alu.ys`       |  3 |  634 | 114 | clean |
| `gft_dot4_tile` | `synth_gft_dot4_tile.ys` |  4 |  705 | 124 | clean |
| `gft_dot4`      | `synth_gft_dot4.ys`      | 12 | 1673 | 303 | clean |

`LUTs` sums LUT1..LUT6 (each occupies one 6-LUT site). Standalone tops also infer IBUF/OBUF for
their ports; those are I/O pads that vanish when the unit is a submodule, so they are excluded
above. `gft16_mul` at **1 DSP48E1 + 47 LUT + 18 CARRY4** reproduces the figure carried in the
design notes — the hand-transcribed RTL matches its own spec-derived estimate.

## Fit on the AX7203 (XC7A200T-FBG484)

The part has **740 DSP48E1** slices and **134,600** 6-input LUTs. The `gft_dot4_tile` (a 4-MAC
GF-T dot-product tile) costs 4 DSP + 705 LUT + 124 CARRY4, so the ceiling is:

- by DSP48E1: 740 / 4 = **185 tiles**
- by LUT: 134,600 / 705 ≈ 190 tiles

DSP-bound at **~185 GF-T dot4 tiles** = ~740 GF-T MACs resident at once. Matches the ~180-tile
figure in the design notes.

## Honest boundary — what this does and does NOT prove

- **Proven here:** the GF-T RTL *elaborates and technology-maps* to real 7-series cells with no
  errors, and the resource cost is measured (not guessed). The multiplier, adder, subtractor,
  ALU, and both dot-product structures all synthesize clean.
- **NOT proven here:** place-and-route, timing closure (Fmax), and a loadable bitstream. Those
  need `nextpnr-xilinx` (**not installed in this environment**) plus a real device. `stat` gives
  area, not a clock. No claim of on-silicon execution is made — that remains the single open
  "none" in `docs/VERIFIABLE_COMPUTE.md` and requires the AX7203 in hand + the openXC7 PnR half.
- The numbers are `synth_xilinx -flatten` estimates; a full flow with DSP inference tuning and
  retiming may shift them. Treat as an area floor, reproducible from the `.ys` scripts.
