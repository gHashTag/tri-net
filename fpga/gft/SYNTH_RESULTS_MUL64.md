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

## UART engine top (`gft_mul64_ax7203.v` + `gft_mul64_stream.v`)

The streaming top is now built and byte-level verified:

- **Frame** `[0xAA][0x55][a_off:2][a_mant:8][b_off:2][b_mant:8][cmd]` → **reply**
  `[0xA5][out_off:2][out_mant:8][0x00]` (LE), mirroring `gft_mul32_ax7203.v` widened
  to 8-byte mantissas + a 12-byte TX.
- **`gft_mul64_stream_tb.v` (iverilog) PASS**: full frame folds to the gft_mul64
  result — `1.5² → (9842, 2^61) = 2.25`, `1.0² → (9841, 0)`.
- **Top `synth_xilinx` maps clean**: 16 DSP48E1 + ~541 LUT + 100 CARRY4 + 1 STARTUPE2
  (est. 313 LCs), no errors — the whole engine (CFGMCLK + UART + 256-bit datapath)
  lands on AX7203 primitives (`synth_gft_mul64_ax7203.ys`).

## Status

- **Datapath fit: PROVEN** — GF-T64 multiply closes on AX7203 fabric (16 DSP).
- **UART engine: PROVEN in sim** — framing + fold bit-exact, full top synthesizes.
- **Bitstream + flash: BLOCKED on the board pin map** — the same gate as the whole
  `fpga/gft` package: nextpnr P&R needs the AX7203's verified LED / KEY / UART
  `PACKAGE_PIN`s from the ALINX schematic (`gft_alu_ax7203.xdc` deliberately leaves
  them unasserted rather than invent misleading pins). Once the pins are filled:
  `yosys → nextpnr-xilinx --xdc → xc7frames2bit → openocd pld load`. Physically gated.
