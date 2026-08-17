# Negative controls: proving the harness can fail

Every silicon result in this directory was a pass. A reviewer made the obvious
objection: nothing has ever been shown to FAIL, so a harness stuck at "correct"
would look identical to a working one. That objection was fair and it is now
answered.

## The suite

Five runs, one boot, `ps7_pn_tree` loaded once, FCLK 50 MHz. The mismatch counts
for the two tap mutants were **computed in software first**, then compared with
what the silicon did.

| # | Test | Expected | Measured |
|---|---|---|---|
| 1 | correct input, correct taps | 256 of 256 bit-exact | **256 of 256** |
| 2 | wrong input (`rx_off_raw.hex` against `rx_on` golden) | must fail | **256 of 256 differ**, first at index 0 |
| 3 | tap 7 sign flipped | ~248 differ | **exactly 248**, first at index 7 |
| 4 | taps rotated by one position | ~251 differ | **exactly 251**, first at index 5 |
| 5 | correct input again | 256 of 256 | **256 of 256** |

Log: `results/negative_controls.log`.

## Why this is stronger than "it failed"

Any broken thing fails. What matters here is that it failed **in the way the
model said it would, to the exact count**. 248 and 251 were predicted from the
software model before the board was touched, and the hardware produced 248 and
251. A stuck-at-fail harness, or one whose comparison was accidentally
inverted, would not reproduce those specific numbers.

The first-mismatch index is also diagnostic and correct in each case: flipping
tap 7 leaves outputs 0..6 untouched because the delay line has not yet reached
that tap, and the first divergence lands at index 7. Rotating the tap vector
disturbs things earlier, at index 5. Both match the structure of the fault.

Run 5 matters as much as runs 2-4: it shows the failures were not persistent
damage to the loaded design, and that the harness returns to passing when the
fault is removed.

## What this suite still does not cover

Honest boundary, since the point of this file is to stop overclaiming:

- **The design under test was never modified.** These are input and
  configuration mutants, not bitstream mutants. A fault injected into the RTL
  -- a wrong accumulator width, a missing delay stage -- would need a rebuilt
  bitstream per mutant, which is the proper mutation-testing methodology and
  has not been done.
- **Only three fault classes are exercised**: wrong data, single-tap sign,
  tap ordering. Not covered: stuck bits in the EMIO readback path (a stuck-high
  bit would corrupt every value and be caught, but a stuck bit in an unused
  high position would not), accumulator width errors, and anything that
  manifests only at rates the `devmem` harness cannot reach.
- **The comparison is against a model, and the model is checked against a
  second model** (`model_b.py`), not against an authority. Two formulations
  agreeing raises confidence in the specification; it does not establish that
  the specification is what a customer wants.

---

## Closed 2026-08-03: mutants of the design itself

The boundary above said these were input and configuration mutants, not
bitstream mutants, and that proper mutation testing needs a rebuilt bitstream
per fault. Two were built and run.

**Mutant A -- arithmetic.** The final sum truncated to 18 bits instead of 24,
then sign-extended back. Affects only outputs whose magnitude exceeds 2^17.
**Mutant B -- structural.** The delay line one stage short: `xr[62]` is never
loaded, so tap 62 permanently sees zero. Affects nothing until 63 samples are
in flight.

Both rebuilt through the whole open flow -- yosys, nextpnr, fasm2frames,
xc7frames2bit -- and loaded into the PL. Mismatch counts predicted in software
first.

| Run | Expected | Measured |
|---|---|---|
| unmutated design | 256 of 256 bit-exact | **256 of 256** |
| **Mutant A**, 18-bit accumulator | exactly **95** differ | **95**, first at index 32 |
| **Mutant B**, tap 62 dead | exactly **182** differ | **182**, first at index 62 |
| unmutated again | 256 of 256 | **256 of 256** |

Both first-mismatch indices are structurally correct and neither was predicted
in advance, which makes them the better evidence: mutant A first diverges at
index 32, the first output whose magnitude leaves an 18-bit field; mutant B at
index **62**, exactly when the delay line reaches the tap that was killed.

Timing was unaffected -- 59.48 MHz for A, 57.96 for B against 58.36 for the
original -- so neither mutant was rejected by the tools for an unrelated reason.

Log: `results/bitstream_mutants.log`.

**What this now establishes:** faults injected into the design, carried through
the full build, loaded into silicon, and detected in precisely the predicted way,
with the unmutated design passing before and after. That is a mutation-testing
result, not an assertion of one.

**Still not covered:** two mutants are two mutants. A real campaign scores
hundreds. And both faults chosen here are ones the vector was likely to catch --
the honest next step is a mutant designed to be *hard* to catch, such as an
off-by-one in a tap index the vector barely exercises.
