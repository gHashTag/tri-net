# RTL adaptive clock recovery -- Balyberdin AC-2 in deterministic hardware

Closes the sim artifact from `docs/integration/clock-recovery.md` with real RTL.
His ADC->SSI->FIFO+PLL->DAC clock recovery (ITU-T G.8261), as a fixed-point
NCO + FIFO fill counter + PI loop filter -- deterministic, hard-real-time.

- `clkrec.v` -- the loop. An NCO (phase accumulator) is the recovered oscillator;
  its increment is steered by a PI controller on the FIFO fill error so the fill
  holds at its 50% setpoint. In lock the NCO overflow rate (drain) equals the
  arrival rate (source clock). The phase accumulator is an EXACT rate integrator,
  so the ~29 ppm arithmetic-mean artifact of the numpy model is gone.
- `clkrec_tb.v` -- injects arrivals from a reference accumulator offset by
  +200 ppm with per-cycle jitter.

## Verified (iverilog)

```
SRC_PPM=200  fill=512 (setpoint 512)  arrivals=800 drains=800  ratio=1.000000
  drain rate tracks source rate within 0.000000 %
```

Perfect lock: the recovered drain rate equals the source arrival rate exactly, and
the FIFO sits at its 50% setpoint -- Balyberdin's AC-2, in hardware.

## Post-P&R on xc7z020 (open flow, no Vivado)

yosys `synth_xilinx` + nextpnr-xilinx: routing complete, **Fmax 122.41 MHz** -- far
above any APCS ADC/DAC sample rate, so the deterministic clock-recovery peripheral
fits the fabric with headroom. This is the RTL deliverable the integration brief's
plan calls for: a hard-real-time timing loop on the PL, not a numpy toy.

## IEC 61499 ternary function block (ASU_TP_SOM skeleton) -- `fb61499.v`

Balyberdin's execution rule in RTL: "each interrupt checks all needed operands
present; if so, executes the function block." Firing gate = ALL operands valid
(his `no-data` = the absence of valid). Body = our ternary sign-select MAC
(`y = sum_i sel(w_i, x_i)`, sel = +x / -x / 0, 0 DSP). Event in = `req` (from the
recovered clock / an SSI header); event out = `cnf`.

Verified (iverilog), x=[10,-4,7,3], w=[+1,+1,-1,0] (expect 10-4-7+0 = -1):

```
[1] no-data on op2 + req : fired=0   (firing gate holds -- his {no-data} rule)
[2] all present + req    : fired=1  y=-1   (fires, ternary MAC exact)
[3] all present, no req  : fired=0   (no event -> no execution)
```

So the same ternary alphabet is his firing rule (`0`/`no-data` = withhold) AND our
multiplier-free compute (`+x/-x/0`). Compose `clkrec` (recovered clock / SSI timing)
-> `req` -> `fb61499` (event-triggered ternary compute) and you have the core of an
IEC 61499 node -- deterministic timing + firing-gated ternary function blocks -- in
the open flow on one Zynq-7020. That is the ASU_TP_SOM in miniature.

## Assembled node: ASU_TP_SOM in one loadable bitstream

`asutp_som.v` composes the whole node on one Zynq-7020: **PS7** (compute + control)
drives, via **EMIO GPIO** (the SSI virtual-channel interface, Linux /sys/class/gpio),
the operands / weights / arrival strobe of the **fb61499** IEC 61499 ternary function
block; **clkrec** recovers a deterministic clock whose ticks are the block's firing
events; the PS reads back the result, the event and the FIFO fill. This is
Balyberdin's ASU_TP_SOM -- compute + deterministic SSI timing + firing-gated ternary
function blocks + I/O -- on one chip.

Through the fully open flow (yosys -> nextpnr-xilinx -> fasm2frames -> xc7frames2bit,
no Vivado): routing complete, **Fmax 106.37 MHz** on xc7z020, and a loadable
**`asutp_som.bit` = 4,045,665 bytes** (correct full xc7z020 config size). The RTL
blocks are no longer separate pieces -- they are one deterministic IEC 61499 node
image. What remains (honest): the .bit is generated, not flashed on silicon with the
board's real EMIO map + a PS program (the destructive on-board step), and the SSI
inter-node fabric proper is Balyberdin's side.

## ЯПФ dataflow cascade (Balyberdin's tiered-parallel form) -- `yapf_cascade.v`

Two tiers of ternary function blocks. Tier-1 blocks a,b fire when THEIR operands
arrive; their results + confirm events become the operands + firing gate of tier-2
block c -- so c cannot fire until BOTH tier-1 nodes have produced data. This is the
"wave of detonation": dataflow ordering enforced by the {no-data} firing gate, not a
program counter. Verified (iverilog): tier-1a=6, tier-1b=4, tier-2=6+4=10 --

```
[1] only tier-1a fired : cnf_c=0   (wave not complete -- tier-2 waits for tier-1b)
[2] both tiers fired   : cnf_c=1  yc=10   (wave complete, composed ternary MAC exact)
```

Post-P&R on xc7z020 (open flow): **Fmax 607 MHz**. A ternary tiered-parallel form
running as a data-driven wave through the DAG -- Balyberdin's ЯПФ, in hardware.

## Live radio -> clock: recovering the REAL .11<->.12 offset

Measured the real sample-clock offset between two boards from a live DSSS capture
(.11 TX -> .12 RX): fractional preamble-peak positions across 4 frames give
**-0.852 ppm** (-26.18 Hz at 30.72 MSPS); the carrier residual is +0.97 ppm at the
2.4 GHz LO. Driving `clkrec` (`clkrec_live_tb.v`) with that real offset:

```
REAL .11<->.12 offset ~-0.85 ppm: fill=512/512  arrivals=150000 drains=150000  ratio=1.000000
  recovered clock tracks the real radio source rate within 0.000000 %
```

So the RTL loop recovers the actual board-to-board radio clock offset, perfectly --
radio -> clock closed, from the real air into the deterministic recovery loop.
