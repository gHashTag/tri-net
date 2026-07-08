# QPSK Modem — Results (Вариант M2, throughput)

**Date:** 2026-07-08
**Component:** `trios-mesh` `src/modem.rs`, `src/bin/trios_radiod.rs`, `examples/qpsk_vs_bpsk_bench.rs`
**Commits:** `89b8724` (QPSK modem core), `a21dd56` (daemon wiring, `TRIOS_QPSK`)
**Goal:** double throughput now that carrier tracking is solid (iter9) — the
competitor-ranked #1 skeptic weakness (BPSK spectral-efficiency ceiling).

## What was built

A full QPSK transceiver **alongside** the BPSK one (BPSK untouched → zero
regression). QPSK carries 2 bits/symbol, so the same payload rides in ~half the
samples. Added as a parallel path: `modulate_qpsk` / `tx_shaped_qpsk` /
`rx_recover_qpsk` / `demodulate_qpsk`, QPSK carrier loops
(`dd_phase_track_qpsk`, `dd_residual_omega_qpsk`), Gray mapping (independent
I/Q BPSK axes), 4 symbols/byte. Wired into the daemon behind `TRIOS_QPSK=1`.

**The key design choice — dodging QPSK's 4-fold phase ambiguity.** QPSK carrier
recovery can lock to any of 4 rotations (90°/180°/270°) and silently swap I/Q
bits, corrupting the whole burst even at high SNR. The fix here: keep the
**real-axis BPSK Barker preamble** for timing + *absolute* phase — it pins the
constellation orientation, so there is no 4-fold ambiguity (only the 180° flip,
resolved exactly as in BPSK). This is the standard burst-modem answer and avoids
DQPSK's ~2–3 dB penalty (confirmed by the throughput research).

## Measured — the honest tradeoff (`qpsk_vs_bpsk_bench`, 90-byte frame)

**Throughput (airtime, channel-independent):**
```
BPSK 2988 samples, QPSK 1532 samples  => QPSK 1.95× throughput
```
(Slightly under 2× because the shared BPSK preamble + RRC tails are fixed cost.)

**FER at FIXED noise power per sample (= fixed TX power), rate/robustness menu:**

| σ | BPSK-raw | QPSK-raw | QPSK+FEC |
|------|---------:|---------:|---------:|
| 0.10 | 0.0% | 0.0% | 0.0% |
| 0.14 | 0.0% | 1.6% | 0.0% |
| 0.18 | 0.0% | 18.8% | 0.6% |
| 0.22 | 1.8% | 59.9% | 3.9% |
| 0.26 | 13.0% | 86.8% | 11.0% |
| 0.30 | 40.0% | 95.6% | 21.9% |

**Reading it honestly:**
- **QPSK-raw = free 2× throughput on healthy links** (σ ≤ ~0.10, FER 0%). This is
  the textbook result: BPSK and QPSK are equal at equal *Eb/N0*; the ~3 dB gap
  appears only at fixed TX power, and only shows up as you push toward the noise
  floor (σ ≥ 0.12).
- **QPSK+FEC ≈ 1.06× BPSK-raw airtime** (FEC's 2× bytes cancel QPSK's 2×
  efficiency) and, thanks to the now-net-positive soft Viterbi (iter9), **beats
  BPSK-raw on marginal links at equal airtime**: σ=0.30 BPSK-raw 40.0% vs
  QPSK+FEC 21.9%; σ=0.26 13.0% vs 11.0%.

Three usable operating points → the basis for a future link-adaptive MCS:

| profile | throughput | best for |
|---------|-----------:|----------|
| BPSK | 1× | max robustness / worst links |
| QPSK | 2× | clean links |
| QPSK+FEC | ~1× (BPSK airtime) | marginal links (better FER than BPSK) |

(Adaptive auto-switching is premature for 3 nodes — two static profiles suffice,
per the competitor read. `TRIOS_QPSK` + `TRIOS_FEC` give the profiles today.)

## Hardware smoke (board 11, real AD9361 IQ, QPSK mode, 16 s)

Cross-built armv7, ssh-cat deployed (md5 verified), `TRIOS_QPSK=1`:
- `[radiod] modulation: QPSK (2x)` at boot; real key loaded; node up.
- **90 QPSK frames self-recovered off real AD9361 IQ** — `rx_recover_qpsk`
  demodulates real hardware bursts end-to-end, not just sim.
- **0 panics.** (The 37-byte handshake-over-QPSK path is byte-exact host-side;
  the board's busy 2.4 GHz air just under-samples the 3 s beacon in 16 s.)
- Per-frame throughput/FER over a real 2-node link still needs boards 12/13.

## Reproduce

```
N=3000 LEN=90 cargo run --release --example qpsk_vs_bpsk_bench   # menu + airtime
cargo test qpsk                                                  # 5 QPSK tests
# on a node: TRIOS_QPSK=1 trios_radiod <config>                  # QPSK mesh
```
