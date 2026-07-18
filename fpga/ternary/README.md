# The ternary heart of TRI-NET

> **One multiplier-free primitive (sign-select MAC) builds BOTH a radio and an AI
> transformer on one ~$100 Zynq-7020**, in a fully open flow (yosys/nextpnr/
> iverilog/prjxray, no Vivado). Ternary weights turn every multiply into
> `+x / -x / 0`, so the weight-heavy compute costs **zero DSP**, freeing the DSP
> column so radio and AI coexist on the same cheap chip.

**Headline results (all built + verified here):**

| half   | result                                                                    |
|--------|---------------------------------------------------------------------------|
| radio  | ternary demod **0 DSP / 78 MHz**, demodulates real air, OTA spread-spectrum **35x gain / 99.4x** code-reject, real xc7z020 bitstream via open flow |
| AI     | every transformer block **0 DSP**, systolic GEMM **33 GOPS**, a **trained** ternary transformer runs end-to-end on the engine at **97%** |
| system | 91M IGLA-Coder on one chip (23 MB DDR, 170-565 tok/s memory-bound) + a mesh |

**Read the story:** [`LAYER.md`](LAYER.md) (a full transformer layer) ·
[`MODEL.md`](MODEL.md) (the 91M model on one chip) · [`SYSTEM.md`](SYSTEM.md)
(the internet-from-the-air mesh) · [`nn/TRAINED_MODEL.md`](nn/TRAINED_MODEL.md)
(a trained model that solves a task, 97%).

**Blocks (each a subdir with its own README):** `systolic/` (GEMM + tiling) ·
`cordic/` (RoPE sin/cos) · `ffn/` · `softmax/` (3 divider variants) · `norm/`
(RMSNorm) · `attn/` (DSP budget) · `nn/` (RF classifier + trained transformer) ·
`axi/` (Zynq PS bridge) · `ota/` (over-the-air). This file below is the radio
matched-filter core. `phi^2 + 1/phi^2 = 3`.

---

## Ternary ZeroDSP matched filter -- the compact radio demod

The GF16 correlator (`../gf16/`) spends **8 DSP48E1** because every tap is a full
float multiply. But a matched filter's reference is a *code*, and a code is
naturally ternary `{-1, 0, +1}`. Multiplying a sample by a ternary tap is not a
multiply -- it is a sign-select (`+x`, `-x`, or `0`). So the whole correlator
collapses to a signed adder tree: **zero DSP, zero float normalization**.

This is the t27 "ZeroDSP MAC" idea (`t27/specs/fpga/mac.t27`,
`t27/fpga/verilog/ternary_mac_synth.v`) applied to the radio matched filter.
Ternary weight encoding follows GFTernary / that MAC: `2'b01 -> +1`,
`2'b10 -> -1`, else `0`. SSOT: `t27/specs/numeric/{tf3,gfternary}.t27`.

## Files

- `tern_corr8.v` -- combinational 8-tap ternary matched filter (sign-select +
  adder tree, parameterised sample/accumulator width).
- `tern_corr8_stream.v` -- streaming core: one signed sample/clock in, correlation
  out one clock later; 2-bit taps load through a config port.
- `tern_corr8_stream_tb.v` -- matched ternary code peaks (600 = 6 nonzero taps *
  amplitude 100), a zero-sum DC input nulls (0).
- `ota/` -- REAL over-the-air samples through this RTL.

## Measured, open-source (iverilog + yosys + nextpnr-xilinx, no Vivado)

Same xc7z020clg400-1 target and flow as the GF16 core, head to head:

| metric (xc7z020)        | GF16 `gf16_corr8_stream` | ternary `tern_corr8_stream` |
|-------------------------|--------------------------|-----------------------------|
| tap width               | 16-bit GF16 float        | **2-bit `{-1,0,+1}`**       |
| DSP48E1                 | 8                        | **0**                       |
| LUT (yosys)             | ~3138                    | **~540**                    |
| CARRY4                  | 315                      | **45**                      |
| FF                      | 273                      | 165                         |
| **Fmax (nextpnr STA)**  | **14.29 MHz**            | **78.21 MHz**               |
| full 30.72 MSPS native? | no (needs pipelining)    | **yes**                     |

Ternary is **~6x fewer LUTs, 0 DSP, and 5.5x higher Fmax.** 78 MHz clears the
full AD9361 30.72 MSPS with headroom -- no decimation and no pipelining, both of
which the GF16 core needed. The 8 freed DSP48E1 can go to channel filters or an
NCO.

## It demodulates the real air (ota/)

The same antenna-to-antenna capture used for the GF16 proof (board .13 TX a 1 MHz
tone, board .12 RX, tone at +0.96 MHz), fed through this ZeroDSP RTL with the
ternary sync code `sign(cos(2*pi*k/8))`:

| samples       | code               | RMS \|corr\| |
|---------------|--------------------|--------------|
| TX ON (real)  | matched            | **237.9**    |
| TX ON (real)  | mismatched (3x)    | 47.2 (~5x)   |
| TX OFF (real) | matched            | 14.0 (~17x)  |

The ternary code is a sign-only approximation of the cosine, so its
matched-vs-mismatched margin (~5x) is coarser than GF16's (~15x) -- but its
noise rejection is *better* (~17x vs 4x off), and for a real spread-spectrum
modem the reference IS a ternary PN code by design, so this is the right
primitive, not a compromise. See `ota/README.md`.

## Honest note

Ternary taps quantise the reference to signs only; they do not quantise the
received samples (those stay full int16 from the ADC). That is the correct
split: a matched filter's *code* is ternary, its *input* is the analog signal.
Carrier/timing recovery is still open (SOUL Article V) -- this matched a fixed
code at the measured tone bin.

## The ZeroDSP building blocks around it

The sign-select MAC is one primitive; it builds the whole modem AND the on-board
AI. Every block below is verified in iverilog and uses **zero DSP48E1** (yosys
`synth_xilinx`, xc7z020):

- **`tern_nco.v` -- ternary NCO + BPSK modulator (TX side).** Phase accumulator ->
  8-phase ternary carrier sign(cos), BPSK-modulated by a data bit. No sine ROM,
  no multiplier. `tern_loop_tb.v` closes a full TX->RX loop against
  `tern_corr8_stream`: the correlation peak's SIGN follows the data bit
  (data=1 -> +600, data=0 -> -600 at the alignment phase) -- BPSK demod.
  P&R: 61 LUT, 0 DSP, **Fmax 148 MHz**.

- **`tern_pn_lfsr.v` + `tern_corr_pn.v` -- spread spectrum.** A length-63
  m-sequence (x^6+x^5+1) and an N-tap ZeroDSP despreader. `tern_pn_tb.v`:
  period = 63, autocorrelation peaks at **+63*A** on alignment and sits at
  **-A** for every nonzero shift -- a **63x (~18 dB) processing gain** that
  survives jammers and separates mesh nodes by code phase (CDMA). The 63-tap
  despreader is **0 DSP** (~4268 LUT) where a naive design would burn 63
  multipliers.

- **`tern_dot27.v` + `tern_matvec.v` -- on-board edge AI.** The same sign-select
  MAC as a BitNet-class layer: M neurons x K=27 ternary weights x int8
  activations (t27 27-trit `MAC_WIDTH`). `tern_matvec_tb.v` is bit-exact vs a
  software reference over 20x4 random trials. A 4x27 layer = 108 MACs at
  **0 DSP** (~4516 LUT); a naive layer would need 108 of the chip's 220 DSP48E1.
  One ternary primitive serves both the mesh PHY and its inference.

Together: a ternary radio (NCO -> spread -> despread -> correlate) and a ternary
neural net share one multiplier-free MAC, all fitting in LUT fabric beside the
AD9361 with the DSP block column left entirely free.

## Streaming despreader P&R + the SSOT that fixes its clock

- **`tern_corr_pn_stream.v`** -- the N=63 despreader with a narrow (53-pin) IO so
  it place-and-routes. Verified (`tern_corr_pn_stream_tb.v`): aligned PN peaks at
  N*A = 6300. Post-P&R on xc7z020: **0 DSP, 10484 LUT (9%)**, but **Fmax
  3.87 MHz** -- the 63-wide sum is one combinational adder chain, the same
  deep-path problem the GF16 correlator had. It fits trivially; it is slow until
  the adder is a balanced tree.

- **`tern_corr_pn_tree.v` -- the fix, applied.** Same N=63 despreader but the 63
  sign-selected terms sum through an explicit BALANCED adder tree (64 -> 32 -> 16
  -> 8 -> 4 -> 2 -> 1, depth 6 instead of 63). Verified identical (peak 6300).
  Post-P&R on xc7z020: **0 DSP, 9497 LUT (8%), Fmax 45.38 MHz** -- a **~12x**
  jump from the flat 3.87 MHz, and now **above the full 30.72 MSPS chip rate**.
  Depth, not resources, was the whole problem.

- **The same balanced tree is in the SSOT.** `t27c gen-trit-stdlib` emits the
  canonical ternary HW library -- `trit_multiply`, `trit27_parallel_multiply`,
  **`adder_tree_27`** (a 27 -> 9 -> 3 -> 1 balanced tree), and
  `trit27_dot_product` (**220 LUT, 0 DSP**). Our tree mirrors that SSOT pattern.
  Regenerate the library with:

  ```
  t27/target/release/t27c gen-trit-stdlib > trit_stdlib.v
  ```

  (The generated file is NOT committed here -- its SSOT is t27; this repo mirrors
  the primitive, the spec owns it.)

## A real loadable bitstream, 100% open flow

The ternary correlator goes all the way to a loadable **xc7z020 bitstream** with
no Vivado anywhere: `yosys -> nextpnr-xilinx --fasm -> fasm2frames ->
xc7frames2bit` (all in `regymm/openxc7`) produced a **4,045,664-byte `.bit`** --
the correct full-configuration size for a Zynq-7020. The open deploy path reaches
a real bitstream for the exact chip on the P201Mini.

Honest boundary (NOT done): the `.bit` is generated, but it is not loaded on a
board. Two reasons, both real: (1) the correlator's ports auto-place to physical
FPGA pins -- to be driven by the Zynq PS over AXI it needs the PS7/AXI-GP
boundary the ADI reference design provides, which openXC7 does not wire up for
us; (2) loading any PL image on .13 disconnects the live AD9361 datapath, so the
working radio node is not overwritten without explicit go-ahead (reversible by
reboot to SD-boot). The bitstream flow is proven; on-board load + PS-AXI
integration is the remaining bring-up.

## Over-the-air PN (honest, partial) -- see ota/pn_over_air.md

Arbitrary-waveform DMA transmit over the air is proven (a host-generated buffer
fed continuously to `iio_writedev` on .13, received strong on .12). A PN-spread
capture despreads with ~6.8x correct-vs-wrong-code discrimination over the air,
but the full 63x sidelobe rejection / clean CDMA phase separation needs a proper
acquisition front end (exact chip rate + carrier derotation). Not claimed as
done. Details and numbers in `ota/pn_over_air.md`.
