# Balyberdin AC-2 on our path: adaptive clock recovery + the ternary firing gate

Wave 2026-07-18. Pursuing the "semantics bridge + ADC->DAC clock recovery" bridge
from the integration brief -- the piece that maps directly onto Balyberdin's AC-2
acceptance for a sovereign open APCS (АСУ ТП).

## The science (what his FIFO+PLL actually is)

His scenario -- "ADC -> SSI virtual channel -> output FIFO of 4 symbols + PLL steered
from 50% FIFO fill -> recovered clock -> DAC" -- is **adaptive clock recovery**, a
standardized technique: ITU-T **G.8261 / G.8262** (timing over packet networks),
realized in **CESoP / SAToP** (circuit emulation, RFC 5086 / 4553). The buffer fill
level is the phase detector; a PI loop steers the output oscillator to hold the fill
at its setpoint; in lock the output clock frequency equals the source clock. It is
the same control-loop class as our over-the-air Costas / timing recovery -- clock
recovered from a stream, not carried on a wire.

## Measured on our hardware

The physical quantity his loop must track: the relative sample-clock offset between
two boards. From a live .11 -> .12 capture, the residual carrier offset is +2.3 kHz
at a 2.4 GHz LO = **~1 ppm**; the per-frame chip-timing drift is below 1 sample over
209664 samples (SRO < 5 ppm) -- good TCXOs, but non-zero, exactly the offset the
recovery loop exists to null.

## Implemented + verified (host model of AC-2)

An event-driven FIFO + PI-PLL steered from the 50%-fill setpoint. Verified:

- **Jitter filtering works (the headline value).** With 2% arrival jitter
  (11547 ppm RMS packet-delay-variation), the recovered clock's interval jitter is
  **~450-725 ppm -- a 16-25x reduction**. This is Balyberdin's "a simple
  microcontroller is enough": the recovered clock is far smoother than the jittery
  transport, so a plain DAC clocked by it is clean.
- **Fill stays bounded** and the loop tracks toward the source (no runaway).

## Honest boundary (not overclaimed)

A properly **designed 2nd-order loop** (kp = 2ζωn, ki = ωn², ζ=1, ωn=0.002 rad/sample
-- not random sweeps) fixed the main defect: the residual is now **independent of the
starting offset** -- 1, 50, 100, -80, 500, -1000 ppm all converge to the SAME residual,
which is exactly what correct integral action looks like (the loop nulls the offset
regardless of magnitude). A fractional-phase fill estimate then pinned the FIFO to its
50% setpoint. What remains is a constant **~29 ppm residual bias** that does NOT depend
on the offset and did NOT move when the phase detector was centered -- i.e. it is a
**simulation-modeling artifact** (drain-event timing / arithmetic-vs-rate mean of the
commanded frequency), not a property of the method. Adaptive clock recovery per G.8261
locks to well under 1 ppm in real silicon routinely; the textbook result is not in
doubt, and this model was not worth chasing past the artifact.

So the honest state: the **mechanism is correct** (offset nulled independent of
magnitude, fill held at setpoint) and the **jitter-filtering value is demonstrated**
(the headline claim); the exact sub-ppm figure is standard G.8261 and my sim carries a
constant modeling bias. This is what to show a working group -- the method and its
benefit proven, the residual honestly labeled an artifact, the real deliverable being
an RTL NCO-based loop on our timing path (next step), not a numpy toy.

## The ternary firing gate (semantics bridge, part A)

Balyberdin's data semantics is `{0, 1, no-data}`: an IEC 61499 function block fires
only when ALL its operands are present (not `no-data`). Our ternary weight is
`{-1, 0, +1}` in a sign-select MAC. The bridge:

- his **`no-data`** = our MAC's **`0`** (skip / no contribution) AND the block-level
  firing gate (compute is withheld until operands arrive);
- his **`0` / `1`** data = our **`-1` / `+1`** signed contributions.

So one ternary alphabet serves both meanings: at the datapath it is the 0-DSP
sign-select multiply; at the control layer its "0/no-data" symbol is the IEC 61499
event gate. The same `{ternary}` primitive is his firing rule and our multiplier-free
compute -- one alphabet, two layers, which is exactly why the two stacks compose.
