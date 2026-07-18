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
