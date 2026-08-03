# Prior art: the question that gets asked first, answered before it is asked

"Is 'no multipliers because the weights are +/-1/0' novel in 2026?"

**No. It is 1979 prior art, and the pitch must never claim otherwise.**

Verified findings from an adversarial literature pass, 2026-08-03. Only items a
reviewer re-checked against the primary source are listed.

## The most damaging reference

**US 4,270,179 (Ricoh), filed 1979-06-29, granted 1981-05-26, expired 1998.**
Confirmed text: *"Rather than assigning zero value a polarity, which would tend
to create a bias, the signum operation is replaced with the 'tern' (for ternary)
operation."* This is the idea, named, forty-seven years ago.

Scope worth knowing: it is an adaptive-gradient (LMS) patent, so the ternary
applies to the *operands*, not to a stored weight bank. That is a narrower
overlap than the headline suggests -- but it is not narrow enough to support a
novelty claim.

**US 7,395,291 (Univ. of Hong Kong, filed 2004, expired Feb 2024)** covers
related ground and is also expired.

Expired prior art is not a freedom-to-operate problem. It is a *positioning*
problem: it means the arithmetic cannot be the story.

## A number this project has been quoting wrongly

The three-level correlator efficiency figures "0.81 / 0.88" conflate two rows of
the same table. Against IRAM Table 6.1: at Nyquist the values are **0.64
(1-bit), 0.81 (3-level), 0.88 (4-level / 2-bit)**; at 2x oversampling 0.74 /
0.89 / 0.94. **0.88 is the four-level row, not a three-level oversampled
figure.**

And more important: **those efficiencies price quantisation of the DATA, not of
the WEIGHTS.** This design quantises only the reference taps and keeps the
sample path at full signed 16-bit from the ADC. Quoting a 1.96 dB data-
quantisation loss against a ternary *weight* scheme is simply the wrong number
for the wrong thing. Cited correctly, the argument gets *stronger*, not weaker.

## What to claim instead

Not the arithmetic. The measured engineering result:

- 8-tap and 63-tap correlators, **256 of 256 outputs bit-identical** to the
  software reference, in programmable logic, on real over-the-air samples
- **timing closed and reported** at the radio rate, with a committed log
- **byte-reproducible bitstreams** end to end, demonstrated over five runs
- an **open build flow** that has now been shown to place and route IBUFDS,
  PLLE2, OSERDESE2 and ISERDESE2

Cite Weinreb (1963) and Cooper (1970) yourself, in the room, before anyone else
does. A team that names its own prior art is trusted on everything after it.
