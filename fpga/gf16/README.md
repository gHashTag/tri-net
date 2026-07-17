# GF16 — the numeric format for the tri-net radio DSP

## Decision

The tri-net radio modem's DSP (matched-filter correlator, NCO phase, filter
taps) uses **GoldenFloat GF16** as its numeric format. Studied the whole
GoldenFloat family (t27 `FORMAT_REGISTRY.md`, `conformance/FORMAT-SPEC-001.json`,
CLARA erratum) and GF16 is the clear choice:

- It is the **PRIMARY** format of the TRI-NET line and the only width with
  hand-built Verilog top-levels.
- Per the CLARA GF-multiplier erratum, **every other GF multiplier width
  (GF8/12/20/24/32) is numerically BROKEN** as submitted; GF16 is the **only
  correct** one, and only after the one-line fix (`mant_rounded [8:0] -> [9:0]`).
  That fix IS present in the Verilog copied here.
- 16 bits is the right width for a radio correlator: wide enough for the dynamic
  range of I/Q + tone references, narrow enough that a 4-tap MAC is 4 DSP48E1s.
- NOT TF3 (balanced ternary — a different, AI-mesh use), NOT FP8/NF4 (PLANNED,
  not implemented in the line).

GF16 layout: `[ S(1) | E(6) | M(9) ]`, bias 31, value `(-1)^S * 2^(E-31) * (1 + M/512)`.
SSOT is `t27/specs/numeric/gf16.t27` + `FORMAT-SPEC-001.json`; these `.v` files
are the verified realization, copied so the modem can sim/synth standalone.

## Verified, open-source (NO Vivado)

- `iverilog` differential sweep vs a float reference: **400/400 pairs CLEAN**
  (`gf16_mul_sweep_tb.v`, tol 1/256) — the exact RTL-differential-sweep gate the
  CLARA erratum prescribes.
- `iverilog` unit tests: gf16_mul 14/14, gf16_dot4 6/6.
- `yosys synth_xilinx` (7-series): `gf16_mul` = 1 DSP48E1 + 13 CARRY4 + ~127 LUT;
  `gf16_dot4` (the 4-tap correlator MAC) = 4 DSP48E1 + LUTs.
- **Full `nextpnr-xilinx` place-and-route now runs** for the real radio FPGA
  (`xc7z020clg400`, chipdb built from prjxray-db in `regymm/openxc7`): see the
  streaming core section below for measured post-P&R numbers.

## How this connects to bytes-over-radio

The blocker for bytes over the air is a CLEAN modulator/demodulator, not the
link (a steady tone was received strong, magnitude 202). A GF16 correlator is
the demod's matched filter: multiply the received I/Q by each reference tone and
accumulate = `gf16_dot4`. This is the numeric core of the FPGA modem that
replaces the jittery shell-toggled DDS.

## The boundary (honest)

- Proven open-source synth+flash target: **ALINX AX7203, Artix-7 xc7a200t**
  (`fpga-synth` skill, openXC7). The AX7203 is NOT connected right now.
- The radio itself is on the **Zynq-7020** P201Mini, where the openXC7 flow does
  **not yet apply** (needs an `xc7z020` chipdb + PS/FSBL boot). So the GF16 modem
  is verified and synthesizable today, but flashing it beside the AD9361 on the
  Zynq is a separate bring-up (chipdb) not yet done. On the AX7203, when
  connected, the flow is proven end to end.

## The demod correlator, verified (gf16_corr8)

`gf16_corr8` = 8-tap GF16 matched filter (two gf16_dot4 + gf16_add). A matched
filter that lights up on the tone it is matched to and stays near zero otherwise
IS demodulation. iverilog (open-source, no Vivado):

    matched cosine  : corr = 4.007   (want ~4.0 = tone energy, sum cos^2)
    orthogonal sine : corr = 0.000
    mismatched tone : corr = 0.000
    -> the GF16 matched filter SEPARATES the tone

This is the numeric core of the FPGA modem that replaces the jittery
shell-toggled DDS: correlate received I/Q against reference tones, pick the peak.

## The streaming demod core (gf16_corr8_stream) + measured P&R

`gf16_corr8_stream` is the PL-side modem core: one GF16 sample enters per clock,
the correlation of the last 8 samples against 8 reference taps leaves one clock
later. Taps load through a small write port (an AXI-Lite config bank in a real
image). This shape has a sane IO footprint (56 pins, not the flat correlator's
272) so it actually places on the xc7z020, and the taps are runtime registers so
the 8 multipliers are real (yosys cannot fold them away and lie about cost).

Verified in `iverilog` (`gf16_corr8_stream_tb.v`): loading cosine taps and
sliding a matched burst through the stream peaks the registered output at
**4.007** on alignment ("streaming demod works"). All-ones sanity: corr = 8.0.

**Measured `nextpnr-xilinx` post-place-and-route on `xc7z020clg400-1`:**

- Resources (yosys `synth_xilinx`): **8 DSP48E1**, ~3138 LUT, 273 FF, 315 CARRY4,
  56 IO. On the xc7z020 that is **~5.9% LUT, 3.6% DSP, 0.26% FF** -- the modem
  core fits beside the AD9361 datapath with enormous headroom.
- Timing (nextpnr STA): **Fmax = 14.29 MHz**. The single-cycle combinational
  path (8 GF16 multiplies + a 3-level GF16 add tree between the input and output
  registers) is deep. That clears the DECIMATED demod rate used in the live test
  (7.68 MSPS) but NOT the full 30.72 MSPS -- full-rate needs the multiply/add
  tree pipelined. Honest number, actionable next step.

## Live over-the-air demod through this exact RTL (ota/)

`ota/` feeds REAL antenna-to-antenna samples (board .13 TX a 1 MHz tone, board
.12 RX at 30.72 MSPS, received tone at +0.96 MHz, SNR ~47 dB) through
`gf16_corr8_stream`. Matched taps vs the real tone give RMS |corr| 2.30; a
mismatched (3x) reference gives 0.155 (~15x separation) and the TX-off capture
gives 0.55 (~4x). The correlator we synthesize demodulates the air. See
`ota/README.md` for the capture commands and the full table.

## The Zynq path is OPEN with open-source tools (correcting the skill)

The `fpga-synth` skill says the Zynq PL synth is "TBD, needs a chipdb + weeks".
Checked, and that is outdated -- all three pieces exist:

1. **prjxray-db has xc7z020** (`regymm/openxc7` image:
   `nextpnr-xilinx/xilinx/external/prjxray-db/zynq7/xc7z020clg400-1` etc.). The
   fabric database of OUR radio board's FPGA already exists open-source. A
   nextpnr chipdb is not prebuilt but BUILDS from this db (defined bba flow),
   not fuzzing.
2. **nextpnr-xilinx P&Rs 7-series** (present in the image with yosys).
3. **The P201Mini loads a PL bitstream from Linux**: `/sys/class/fpga_manager/
   fpga0` = "Xilinx Zynq FPGA Manager", state `operating`. No JTAG, no Vivado --
   the Zynq PS reprograms the PL at runtime.

Honest boundary that remains: the current PL bitstream IS the AD9361 datapath
(mwipcore/DDS/DMA). A bitstream of just our correlator would disconnect the
radio. The real work is a full PL design that keeps the ADI AD9361 AXI
interfaces AND adds the GF16 modem -- substantial, but a design task, NOT a
toolchain impossibility. The tools and the board's load path are proven.
