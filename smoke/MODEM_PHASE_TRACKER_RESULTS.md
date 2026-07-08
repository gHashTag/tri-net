# Modem Phase Tracker — Results (Вариант M, modem robustness)

**Date:** 2026-07-08
**Component:** `trios-mesh` `src/modem.rs` (+ `examples/modem_failure_census.rs`)
**Commit:** `61cff89`
**Goal:** attack the proven bottleneck from iter8 — frame loss dominated by
whole-frame failures that scale with frame length — the single highest-leverage
software lever (also the competitor-ranked #1 modem weakness).

## Doctrine: measure the cause before changing anything

Rather than guess, `modem_failure_census` classified every failed frame:
`nolock` (no preamble sync) vs `corrupt` (locked but wrong bytes), and for
corrupt frames, whether the byte errors were head- or tail-biased.

| σ | frame | FER | of failures: nolock | corrupt | byte errors |
|---|-------|----:|--------------------:|--------:|-------------|
| 0.16 | 90 B | 8.7% | 0% | 100% | 94% in 2nd half |
| 0.20 | 90 B | 27.8% | 0% | 100% | 87% in 2nd half |
| 0.16 | 200 B | 23.0% | 0% | 100% | 90% in 2nd half |
| 0.20 | 200 B | 48.2% | 0% | 100% | 83% in 2nd half |

**This refuted the obvious guess.** The Barker preamble *never* failed to lock
(0% nolock), even at 38% FER — so preamble/sync design was the *wrong* lever
(and so was the initial research premise). Every failure was carrier-domain, and
the errors were strongly **TAIL-biased** — the signature of **carrier phase
drift**: the 13-symbol pilot's residual ω leaves a phase ramp worst at the frame
tail, so loss scales with length. Exactly the iter8 length-dependence, now
explained.

## Fix — decision-directed residual phase tracker

A first-order decision-directed loop added as a second stage in the shared
receiver front-end (`recover_symbols`, so both hard and soft receivers benefit).
After the global (ω, θ) derotation it walks the symbols from the well-corrected
front, hard-decides each BPSK symbol, measures its phase error against ±1, and
steers a running phase correction. On a clean frame every error is ≈0, so it is a
no-op; it only acts when there is drift. **No wire-format change, no overhead**
(unlike mid-frame pilots). `PHASE_TRACK_ALPHA = 0.05`.

## Result — before → after

| case | FER before | FER after |
|------|-----------:|----------:|
| 90 B, σ=0.16 | 8.7% | **0.0%** |
| 90 B, σ=0.20 | 27.8% | **0.3%** |
| 200 B, σ=0.16 | 23.0% | **0.0%** |
| 200 B, σ=0.20 | 48.2% | **0.5%** |

The tail bias is **gone** — the residual corruption is now AWGN-uniform — and the
**length penalty is gone** (200 B now as good as 90 B). This is a large effective
link-budget / range extension on the same PHY, and it unblocks the long frames
(photo/video) that suffered most.

## Downstream — FEC flips net-positive (iter8 verdict reversed, honestly)

iter8 measured FEC as net-negative *because* frame loss was length-dominated
(rate-1/2 doubles length → doubles that exposure). With the drift removed, the
residual failure is ordinary AWGN bit errors — exactly what FEC corrects. Now
(`fec_fer_bench`, 90 B):

| σ | raw FER | FEC FER | gain |
|---|--------:|--------:|------|
| 0.24 | 5.8% | 0.0% | 174× |
| 0.26 | 13.6% | 0.1% | 102× |
| 0.28 | 24.8% | 0.2% | 106× |
| 0.30 | 39.5% | 0.4% | 99× |

**~100× fewer lost frames across the marginal regime.** FEC's value was gated on
modem robustness, exactly as the iter8 finding predicted. FEC stays opt-in only
because rate-1/2 halves goodput (enable on marginal/long links, off on clean).

## Hardware smoke (board 11, real AD9361 IQ, 16 s)

Cross-built armv7, ssh-cat deployed (md5 verified), run on the live air:
- Real key loaded, node up.
- **88 frames self-recovered off the air** — the new phase-tracker modem
  demodulates real AD9361 IQ end-to-end. Handshake beacon still self-received 5×.
- **0 panics.** (Per-frame FER over a real 2-node link still needs boards 12/13;
  board 11 alone confirms modem-path integrity on real hardware.)

## Reproduce

```
SIGMA=0.20 LEN=200 N=6000 cargo run --release --example modem_failure_census
SIGMA=0.30 N=3000 cargo run --release --example fec_fer_bench
cargo test phase_tracker      # regression guard
```
