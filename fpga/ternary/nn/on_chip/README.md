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

## TRAINED model on the chip: 5-class network sensing, learned from its own air

`tools/ternclass` now also ships **`ternnet`** -- not hand-set rules but a model
TRAINED on a labeled dataset collected over this very link (.11 TX -> .12 RX,
2.4 GHz): 960 windows, 5 classes x 2 TX power levels, split at CAPTURE level
(train and test never share a capture). Classes map to real mesh-network tasks:

| class | network meaning |
|-------|-----------------|
| noise | channel clear -> OK to transmit (CSMA) |
| tone  | narrowband interferer / jammer |
| dsssA | mesh node A is talking (its PN code) |
| dsssB | mesh node B is talking (its PN code) |
| wide  | foreign wideband signal (uncoded chips) |

Distinguishing dsssA / dsssB / wide is the genuinely learned part: random chips
show ~0.35 chance-correlation against any 63-chip code, a matching code shows
0.7-0.9 -- the net learns that boundary from data.

**Results:** float MLP 99.8% test == **ternary MLP 99.8% test** (zero loss from
ternarization; every weight in {-1,0,+1}; 208 weights = **52 bytes**). Live on
fresh air, on the board's ARM PS: **9/10 correct** across all 5 classes (the one
miss: a 0.53 ms window catching a weak stretch of the dsssA correlation, feature
0.54 in the boundary zone -- majority-of-3 voting is the known fix). Latency
273 ms / 16384 samples on the Cortex-A9 (dominated by the two PN correlation
searches).

**Hard lessons this milestone forced (all real, all fixed):**
- Board .11 CRASHED mid-collection -> first dataset was garbage-labeled; a model
  trained on it scored exactly chance (20%). GIGO, caught by feature
  instrumentation, not by loss curves.
- After the cold recovery cycle the board booted with default **TX LO 2450 MHz**
  vs the receiver's 2400 -> zero signal; classic identity mismatch, found by
  reading the radio config, fixed with one write.
- The collection loop now VERIFIES every capture (noise floor sane, code
  structure visible for the labeled class) before accepting it -- the rig-check
  discipline applied to dataset building. It caught both failures above and one
  wrong verifier threshold (wide's chance-correlation is ~0.35 vs 63-chip codes,
  not <0.22).

## Closed into a network action: majority voting + a CSMA gate (3 nodes live)

Two follow-ons, verified on all three boards (.11 and .13 as transmitters, .12
sensing):
- **`ternnet` majority-of-3 voting** splits each capture into 3 blocks and takes
  the majority class. It fixed the one boundary miss: live on fresh air, now
  **5/5 classes exact** (noise / tone / dsssA / dsssB / wide), the previously
  marginal dsssA reading pA=0.96 with a clean 3-0 vote.
- **`csma`** closes the classifier into an actual radio-card decision: sense the
  channel, then `class=noise -> "CLEAR: transmit"`, anything else ->
  `"BUSY (<class>): defer"`. Live: empty air -> CLEAR, an occupied channel
  (jammer / another node) -> BUSY+defer, cleared again -> CLEAR. The AI is now a
  transmit gate, not just a label.

`.13` was recovered as node B (password was the standard `analog`; after its cold
cycle it had booted with TX LO 2450 vs the mesh's 2400 -- the same identity
mismatch as .11, fixed by one write), giving a real 3-node rig: node A and node B
each transmit their own PN code and .12's trained ternary model names who is on
the air.

## Bridge to IGLA-Coder: a TRAINED ternary TRANSFORMER on the node silicon

The same dataset -> QAT -> weights -> ARM pipeline, extended from an MLP to a real
**transformer** -- 1 self-attention head (softmax) + FFN, EVERY projection weight
(Q, K, V, O, FFN, head) in {-1,0,+1}. Task chosen so attention is genuinely
required: a positional lookup (token 0 selects a position; the answer is the value
there -- the model must attend from the query to the selected position).

- **Training:** float transformer 96.0% test vs **ternary transformer 100.0%
  test** (ternarization here acts as a regularizer). 2176 ternary weights
  (1252 nonzero) = **544 bytes**; float embeddings 224 params.
- **On the chip:** `xfmr` (Rust, armv7 musl) reproduces the exact forward
  (embed+pos, QK^T/sqrt(d) softmax attention, A*V, O-proj, FFN, classify) and runs
  on .12's Cortex-A9: **12/12 fresh cases correct**, ~2 ms/inference.

This is the architecture of the 91M IGLA-Coder (ternary attention + FFN) in
miniature, trained and executing on the radio node's own ARM -- the concrete
bridge from "the transformer blocks verified in simulation" to "a trained ternary
transformer runs on the silicon."

## Live AI-driven mesh MAC (sense-then-transmit)

Closed the CSMA gate into a running loop on .12: sense the channel with the
trained model, and TRANSMIT a beacon only on `CLEAR`. Live, 3 scenarios:

| air state | AI verdict | action |
|-----------|-----------|--------|
| empty | CLEAR: transmit | beacon TX |
| node B (.13) on air | BUSY (dsssB): defer | held silent |
| clear again | CLEAR: transmit | beacon TX |

The MAC decides correctly every time and even names the occupying node (dsssB) --
an AI-native medium-access layer, not a fixed energy threshold. The beacon
physically reaches the peers (22x preamble lock), but a clean BER=0 payload decode
happens only when **.12 is the receiver**: boards .11 and .13 both show a
good-lock / bad-payload RX artifact (~4-5/8 at 22x lock) -- a per-board AD9361
calibration issue seen throughout this rig, NOT a protocol fault (every .x -> .12
link decodes BER=0). Clean .12 -> peer payload delivery awaits per-board RX
calibration; the AI-gated medium access itself is proven live.
