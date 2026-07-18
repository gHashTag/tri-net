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

## Native version: the same net as a cross-compiled ARM binary

`../../../../tools/ternclass/` is the same ternary classifier in Rust, cross-compiled
to `armv7-unknown-linux-musleabihf` (static musl, 337 KB) and deployed to the PS.
It reads the raw `iio_readdev` byte stream directly (no `od`), so the whole
pipeline is just `iio_readdev | ternclass` on the board:

| air condition | energy | flips | class (native binary) |
|---------------|-------:|------:|-----------------------|
| noise         | 8.3    | 0.557 | **noise** (correct)   |
| tone          | 536.7  | 0.000 | **tone** (correct)    |
| spread        | 571.0  | 0.031 | **spread** (correct)  |

3/3 correct, **~10 ms latency for 8192 samples** on the Cortex-A9. This is the
awk demo upgraded to real compiled code -- the step toward running the actual
trained ternary model on the same PS. Build with
`cargo zigbuild --release --target armv7-unknown-linux-musleabihf`.

Note: the on-chip demo needs the RX in MANUAL gain -- in AGC (`slow_attack`) the
front end amplifies the noise floor to signal levels. The classifier keys on the
**phase-flip rate**, which is invariant to signal level (noise ~0.5-0.8, tone
~0.000, spread ~0.03), so it survives a drifting noise floor -- verified **9/9
across 3 runs x 3 conditions** in the linear range. Its one real sensitivity is
RX **saturation**: an overdriven signal (energy in the thousands) clips the ADC
and scrambles the phase, so keep TX/RX gains in the linear range (a receiver-gain
concern, not a classifier flaw). It is a small hand-set net -- a spectrum-awareness
detector -- not the trained transformer; the point it proves is the shared ternary
primitive running AI on the radio node's own silicon.
