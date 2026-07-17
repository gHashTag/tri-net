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
  `gf16_dot4` (the 4-tap correlator MAC) = 4 DSP48E1 + LUTs. Full P&R needs
  `nextpnr-xilinx` (not installed here) but synthesis maps cleanly.

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
