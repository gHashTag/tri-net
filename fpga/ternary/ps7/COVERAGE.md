# What the bit-exact runs did and did not cover

An adversarial review found three real gaps in the 256-of-256 results. All three
were confirmed by recomputation from the committed data, and the first two are
now closed.

## What the original vector never touched

Recomputed from `ota/rx_on_raw.hex` and `pn_golden.txt`:

| | range used | field available |
|---|---|---|
| samples | **-81 .. +78** | +/-32767 |
| correlator output | **-494 .. +500** | +/-8388608 (24-bit) |
| tap states used | **{+1, -1}** | {+1, 0, -1} |

So the arithmetic never produced a sum anywhere near the accumulator's
capacity -- peak 500 against a field of +/-8 388 608 -- and at N=63 **the ternary
zero, one of the three states the whole design is named for, was never exercised
at all**. The 8-tap vector does contain zeros; the 63-tap PN m-sequence is +/-1
by construction and has none.

**Correction, 2026-08-03.** An earlier version of this file said "the
accumulator's bits 10..23 were never nonzero". That is false, and the error is
worth recording because it is the kind that flatters the writer. 129 of the 256
golden values are negative, and a negative number in two's complement sets its
high bits: -494 is `0xFFFE12`. The bitwise OR of all 256 values is `0xFFFFFF` --
**every one of the 24 readback bits toggles**. What the vector fails to exercise
is the *magnitude* of the sum, not the width of the bus. A stuck bit in the
readback path would have been caught; a carry defect in the high adders would
not.

A carry defect above accumulator bit 9, or a mis-decoded `2'b00` tap, would have
passed every run.

## Closed: a stress vector that hits all of it

`stress_taps.txt`, `stress_samples.hex`, `stress_golden.txt`, generated
alongside the reference:

- **21 of 63 taps forced to the ternary zero**, so all three states appear
- samples spanning the **full +/-32768**
- correlator output spanning **-344 576 .. +180 474**, reaching accumulator
  **bit 18** instead of bit 9

Result, on silicon, FCLK 50 MHz, `ps7_pn_tree`:

```
anchor: 0x47C0 (expected 0x47C0)
=== VERDICT: 256 of 256 bit-exact against the software reference ===
EXIT=0
```

Log: `results/stress_coverage.log`.

## Still open, and stated plainly

**The reference is not independent.** `pn_reference.py` says so in its own
docstring: *"The arithmetic is written the way the hardware does it."* It is a
transliteration of the RTL, so a shared misconception -- a wrong truncation rule,
a wrong tap ordering convention -- agrees with itself and passes. This is exactly
the criticism this project levelled at its own earlier claims and it applies
here too. A genuinely independent model (different author, different language,
written from the spec rather than the RTL) would raise the value of every
bit-exact result in this directory.

**"Over-the-air" does no work in these claims.** Peak-to-RMS of the correlator
output on the OTA capture is **1.796**. The project's own PN link reports a
peak-to-mean of **89.6x** with BER 0 (`ota/pn_over_air.md`). This capture is not
a despreadable signal; correlating it is a numerical exercise on 256 real-valued
samples, and no detection result follows from it. `rx_off_raw.hex` sits in the
same directory and was never used as a negative control.

**The `devmem`-driven runs are structurally blind to timing.** One sample per
host write gives the combinational tree milliseconds to settle, so a design that
closes at 5 MHz returns the same 256/256 as one that closes at 58. Only the
at-speed run (`ATSPEED.md`) says anything about timing, and it is the one that
found the 100 MHz overclock.

---

## The stress vector was worse, and the reason is instructive

I built `stress_*` on the assumption that full-scale samples and a wider output
range must exercise more of the circuit. That assumption is wrong, and measuring
it was worth more than the vector was.

Carry-element coverage of the balanced adder tree -- 63 adders x 23 carry
positions = 1449 elements -- computed by simulating every carry:

| Vector | elements activated | adds over the OTA capture |
|---|---|---|
| the real OTA capture, PN taps | **1426** | -- |
| my `stress_*` (16 distinct values, 21 zero taps) | **937** | **0** |
| random full-scale, PN taps | 1426 | 0 |
| random full-scale, 9 zero taps | 1219 | 0 |
| all of the above together | **1426** | -- |

**My stress vector covers a strict subset of what the real capture already
covered.** Two reasons, and both were predictable had I thought about it:

1. **Zeroing 21 of 63 taps deletes terms.** A zero tap contributes an
   identically-zero operand, and `a + 0` generates no carry at any bit. Every
   adder downstream of a zeroed term loses activity. I added the ternary zero
   for functional coverage -- a legitimate goal -- and paid for it in structural
   coverage without noticing.
2. **Carries are driven by bit-pattern diversity, not by amplitude.** My vector
   cycled 16 distinct values; the real capture has 128. Small numbers with
   varied low bits produce more distinct carry patterns than a handful of huge
   ones. Magnitude only decides *which* bit positions are reachable at all, and
   with 63 terms even -81..+78 propagates far up the tree.

## 1426 is a ceiling, not a score

Driving 2256 samples -- the real capture plus 2000 random full-scale values --
still reaches exactly **1426**. The 23 unreachable elements are all in **adder
31**, which is level 1's last: it sums `term[62] + term[63]`, and since there
are 63 taps padded to 64, `term[63]` is identically zero. Adding zero never
carries.

**Those 23 positions are dead by construction and no stimulus can reach them.**
The real capture was already at the achievable maximum before I started.

Two consequences worth keeping:

- **Report coverage against 1426, not 1449.** A metric with unreachable elements
  in the denominator understates every vector that is measured against it.
- **The pad adder is dead logic.** `term[63]` is a constant zero, so adder 31 is
  a 24-bit adder wired to compute `x + 0`. Synthesis will fold it, but it is
  worth removing at source rather than relying on the tool -- and worth
  remembering that the padding to a power of two is not free in the RTL as
  written.

The better vector remains the one that maximises value diversity across the
sample field. `div_*` (256 random full-scale values, 9 zero taps for functional
coverage of the ternary zero) is committed alongside for that purpose, but it
should be understood as a *functional* complement to the OTA capture, not a
structural improvement on it.
