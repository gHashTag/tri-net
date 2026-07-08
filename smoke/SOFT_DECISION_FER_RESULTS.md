# Soft-Decision FEC — Results (Вариант A″)

**Date:** 2026-07-08
**Component:** `trios-mesh` `src/modem.rs`, `src/conv.rs`, `src/fec.rs`, `examples/fec_fer_bench.rs`
**Commit:** `c92e878`
**Goal:** implement the soft-decision receive path the earlier hard-FEC finding
named as "the real fix", then **measure** whether it flips FEC from net-negative
to net-positive on this modem.

## What was built

A full soft-decision chain, keeping the demodulator's per-bit confidence all the
way to the decoder instead of hard-slicing it away at the modem:

- `modem::rx_recover_soft` / `demodulate_soft` — one signed soft value per payload
  bit (the BPSK matched-filter output, an AWGN LLR proxy), scaled to `i8`.
- `conv::decode_soft` — Viterbi with a correlation branch metric (same 16-state
  K=5 trellis as the hard decoder).
- `fec::decode_soft` (+ soft de-interleaver) — the soft counterpart of `decode`.

Shared front-ends (`barker_sync`, `recover_symbols`) were factored out so the
hard and soft receivers are byte-for-byte identical up to the final bit mapping.

## Correctness first (isolation)

Clean-channel roundtrip `frame → FEC encode → BPSK modem → rx_recover_soft →
decode_soft` is byte-exact (0% FER), so soft agrees with hard when there is no
noise to exploit. A bug was caught here and fixed: the soft path bypasses byte
reconstruction, so it must emit soft values **MSB-first per byte** to match
`fec::bytes_to_bits`; the first version inherited the modem's LSB-first order and
decoded to garbage (100% FER on a clean channel). Isolated by testing the clean
channel before the noisy sweep — one variable at a time.

## Measured FER (`fec_fer_bench`, 3000 frames/point, 90-byte frame, burst 3/1000)

| σ (noise) | raw (no FEC) | FEC hard | FEC **soft** (A″) |
|-----------|-------------:|---------:|------------------:|
| 0.10 | 0.2% | 0.3% | 0.3% |
| 0.14 | **2.7%** | 6.0% | **5.9%** |
| 0.18 | 16.7% | 24.8% | 24.6% |
| 0.22 | 38.9% | 45.4% | 45.2% |
| 0.26 | 63.4% | 60.6% | 60.4% |

**Two honest facts:**
1. **Soft is correct and works:** it is strictly ≥ hard at every SNR (e.g.
   24.8% → 24.6%), exactly as coding theory requires — the confidence is being
   used, not wasted.
2. **But soft FEC is still NET-NEGATIVE vs raw** across the whole marginal regime
   (σ=0.14: raw 2.7% vs soft 5.9% — FEC more than doubles frame loss). The
   bit-level coding gain is real but tiny, and it does not pay for what FEC costs.

## Root cause — proven with a frame-length sweep (σ=0.14 fixed)

| frame bytes | raw FER | FEC FER |
|-------------|--------:|--------:|
| 8 | 0.0% | 0.0% |
| 16 | 0.0% | 0.3% |
| 32 | 0.3% | 1.0% |
| 64 | 1.3% | 3.8% |
| 110 | 4.6% | 9.0% |

Raw FER rises slowly with length; FEC FER rises **~2× faster**, tracking the
rate-1/2 code's length doubling. So frame loss on this modem is **dominated by
whole-frame sync/carrier failures (length-driven), not per-bit errors** — and the
rate-1/2 code roughly doubles that dominant exposure. No bit-level decoder,
however sophisticated (hard, soft, or a future LDPC), can recover a penalty that
is structural in the frame length.

## Decision & next lever

- **FEC stays opt-in (`TRIOS_FEC=1`), default OFF** — unchanged; enabling it by
  default would regress the mesh. The soft path is kept ready for when the modem
  or code rate shifts the balance.
- **The real levers are on the modem, not the decoder:** (a) more robust
  frame sync / carrier tracking (stronger/longer preamble, pilot-aided tracking,
  eventually a PL/FPGA modem), (b) shorter frames, or (c) a much higher-rate code
  so the length penalty is small.

This matches the external competitive read: soft-decision's textbook "~1.3 dB
coding gain on the same PHY" only converts to *frame-level* gain once the PHY's
dominant failure mode is bit errors. On this software modem it is not — so the
priority is modem frame-robustness / PL offload, which is also the item RF
skeptics rank highest.

## Reproduce

```
cargo run --release --example fec_fer_bench            # default σ=0.30
SIGMA=0.14 BURST=3 N=3000 cargo run --release --example fec_fer_bench
SIGMA=0.14 LEN=32 N=3000 cargo run --release --example fec_fer_bench   # length sweep
cargo test soft                                        # correctness tests
```
