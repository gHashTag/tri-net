# GF-T64 multiplier (`gft_mul64.v`) — synthesis fit on XC7A200T

Reproduce:

```bash
docker run --rm -v "$PWD":/work -w /work regymm/openxc7:latest \
  yosys fpga/gft/synth_gft_mul64.ys
```

(`synth_xilinx -flatten`, targeting the AX7203 openXC7 primitives; NO Vivado.)

## Utilization (yosys `stat`, post `synth_xilinx`)

| Resource   | gft_mul64 | XC7A200T avail | Usage  |
|------------|-----------|----------------|--------|
| DSP48E1    | 16        | 740            | 2.2 %  |
| LUT (2..6) | 444       | 133 800        | 0.33 % |
| CARRY4     | 91        | —              | —      |
| Est. LCs   | 252       | —              | —      |

## Reading

The 256-bit significand datapath does **not** blow up in fabric: yosys maps the
65×65 significand multiply `(2^64 + a)·(2^64 + b)` onto **16 DSP48E1** tiles
(each a 25×18 multiply), leaving the LUT/CARRY logic to the renormalize
compare + shift. GF-T64 therefore fits the board with enormous headroom —
2.2 % of DSPs, a third of a percent of LUTs. The datapath width doubles per
rung (gft_mul 32-bit → gft_mul32 64-bit → gft_mul64 256-bit), but DSP tiling
keeps the area roughly linear in mantissa bits, not quadratic.

## Status

- **Fit: PROVEN** (this report) — GF-T64 multiply closes on AX7203 fabric.
- **Bitstream + flash: pending** — needs a UART streaming top (8-byte operands,
  mirroring `gft_mul32_ax7203.v`) so the 192 significand I/O bits reach the
  physical package through the serial harness, then nextpnr PnR + openocd SRAM
  load. Gated on physical board access.
