# Radio AND AI on one chip -- live, on the Zynq PS

The thesis in one demo: the **same ternary sign-select primitive** that despreads
the radio also runs a neural-net classifier, and both execute **on one xc7z020 at
the same time** -- the AD9361 radio on the PL, the ternary classifier on the ARM
PS. No bitstream swap, non-destructive, the live radio untouched.

## The on-chip pipeline (everything runs on board .12)

```
iio_readdev cf-ad9361-lpc  |  od -An -td2  |  awk -f tern_rfclass.awk
   ^ radio: AD9361 on PL        ^ int16 IQ     ^ ternary MAC net on the ARM PS
```

`tern_rfclass.awk` extracts two features from the captured air -- signal energy
(`|I|+|Q|`) and the fraction of sample-to-sample phase reversals
(`Re(s[n]*conj(s[n-1])) < 0`, which spikes at each BPSK chip flip) -- and runs a
2-layer net whose every weight is in `{-1, 0, +1}`. Each MAC is a sign-select
(`+x / -x / 0`), the identical primitive used by the FPGA despreader and the
BitNet layer, here executed by busybox `awk` on the Cortex-A9.

## Measured live (board .11 TX -> .12 RX+classify, 2.4 GHz)

| air condition | energy | phase-flips | ternary net -> class |
|---------------|-------:|------------:|----------------------|
| transmitter off (noise) | 7.7 | 0.693 | **noise** (correct) |
| pure carrier tone | 140.5 | 0.000 | **tone** (correct) |
| DSSS-BPSK spread | 132.2 | 0.031 | **spread** (correct) |

**3 of 3 correct**, all decided on the board's PS. The flip feature separates the
three cleanly: a pure tone rotates smoothly (0.000 reversals), DSSS reverses phase
at chip edges (0.031), noise is random (0.69). Energy separates signal from the
~7 noise floor.

## Why this matters

Every earlier "AI" result ran in simulation (iverilog) or on the host. This runs
the ternary classifier **on the actual silicon of a radio node**, on real
over-the-air captures, while that node's radio is live -- the concrete "an
autonomous edge node that both talks (radio) and thinks (a ternary net) on one
cheap chip" claim, demonstrated end to end. The classifier is a small hand-set net
(a spectrum-awareness detector, not the trained transformer); the point it proves
is the *co-existence and the shared primitive on one die*, on hardware.

`tern_rfclass.awk` is a hardware bring-up utility (runs on the busybox PS), not
part of the golden .t27 pipeline.
