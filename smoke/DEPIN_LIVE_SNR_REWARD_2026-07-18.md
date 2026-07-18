# Live SNR -> $TRI reward (Helium-class Proof-of-Coverage) on hardware (2026-07-18)

Weak point closed: link-quality-weighted reward (prior wave) used a SYNTHETIC quality
number. Here the quality comes from a REAL measured radio link, end to end on silicon.

## Measured link quality (.13 -> .12, DDS tone + iio_readdev)

Same recipe as the SNR characterization, at two TX powers to emulate two nodes:

| TX gain | role | measured SNR |
|---------|------|--------------|
| -10 dB  | strong-coverage node | **34.6 dB** |
| -50 dB  | weak-coverage node   | **5.8 dB**  |

(noise floor P=2124 with RX tracking on; the -10/-50 split gives a clean ~29 dB
difference from 40 dB of TX attenuation.)

## The verified chain, run on node .12 ARM

`snr_to_quality` (tri_settle.t27: floor 3 dB -> 0, ceiling 40 dB, piecewise-linear)
-> `reward_weighted` (pool split by bytes*quality). Both are golden-pipeline verified
(17 invariants). `qreward 1000 10000 34 5 2` on the node ARM, three nodes each
relaying the SAME 10000 bytes:

| node | measured SNR | quality | $TRI |
|------|--------------|---------|------|
| 0 | 34 dB (strong) | 31 | **939** |
| 1 | 5 dB (weak)    | 2  | **60**  |
| 2 | 2 dB (dead)    | 0  | **0**   |

pool = 1000, paid = 999 (floor division => within pool). Same bytes for all three,
yet the reward tracks REAL coverage: the good link earns ~16x the weak one, and a
link below the floor earns nothing. This is Helium's Proof-of-Coverage idea (pay for
proven coverage, not just presence) closed live on the node's own hardware.

## t27c compiler bug found (again) and worked around

`snr_to_quality` first took `i32` -- t27c narrows a signed `i32 <=` compare to u32,
so a negative-SNR (dead) link would read as a huge value and be paid. Same bug family
as the u64==0 narrowing found earlier. Fix: keep the input UNSIGNED (caller clamps a
negative SNR to 0, which maps to quality 0). Found by reading the generated Rust.

## Honest boundary

- The two "nodes" are the same .13->.12 pair at two TX powers, not two physical nodes.
- SNR is quantized to integer dB into the map; a finer scale is trivial.
- Still no full OTA byte transfer (separate track); this closes the QUALITY loop, not
  the data-carrying loop.

Boards left clean: tone off, TX LO pd=1, RX tracking restored, files removed.
