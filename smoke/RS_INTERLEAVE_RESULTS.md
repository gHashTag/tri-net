# Cross-Block Interleaving — Results (2026-07-08)

**Component:** `trios-mesh` `src/vstream.rs`, `examples/rs_interleave_bench.rs`
**Commit:** `94e495b`
**Goal:** close the iter14 honest finding — a multi-block key frame needs ALL
blocks, so a loss *burst* concentrated in one block wipes the whole frame even
when other blocks have spare parity (survival = per_block^B).

## What changed

`fragment_frame_rs` now emits fragments **cross-block interleaved** (round-robin
across blocks): consecutive on-air fragments belong to different blocks, so a
burst of consecutive lost fragments is spread one-per-block instead of
concentrating in one. **Transmit-order only** — the receiver reassembles by the
block/idx header, so there is no wire change, no decoder change, and no cost.

## Measured (`rs_interleave_bench`, 25 KB key frame = 4 RS blocks, 40% parity)

Bursty channel — equal total loss, just clustered differently (SEQUENTIAL =
block-contiguous order, INTERLEAVED = the default). Key-frame recovery rate over
400 trials:

| burst length | sequential | interleaved |
|-------------:|-----------:|------------:|
| 4 | 100% | 100% |
| 8 | 84% | **100%** |
| 16 | 17% | **72%** (4×) |
| 30 | 2.5% | **18%** (7×) |

- **Small bursts / i.i.d.-like loss: neutral** (a short burst never overwhelms a
  block, so order doesn't matter).
- **Long bursts: large gain** — exactly the fading-dip regime a real radio hits.
  A burst of 16 in one block (sequential) exceeds that block's parity → block
  fails → whole frame lost; interleaved spreads it 4-per-block → within parity.

No regression: the streaming path is still byte-identical on a clean link.

## Why it's free

Interleaving is the classic pairing with a block erasure code: the code corrects
*scattered* erasures well but a *concentrated* burst defeats a single block.
Reordering the transmit sequence converts bursts into scattered losses at zero
overhead. It composes with the RS parity — parity sets how many erasures a block
tolerates, interleaving ensures a burst doesn't dump them all on one block.

## Scope

Host simulation, transport layer. Combined Channel V protection is now:
per-fragment modem robustness (phase tracker) + per-block MDS RS erasure code +
cross-block interleaving against bursts + bounded-latency playout. Remaining V:
2-board over-air measurement, live encoder pipeline.

## Reproduce

```
BURST=16 TRIALS=400 RSPAR=40 cargo run --release --example rs_interleave_bench
cargo test rs_multiblock_is_cross_block_interleaved
```
