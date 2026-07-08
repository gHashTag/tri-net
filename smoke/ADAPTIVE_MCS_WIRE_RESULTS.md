# Per-Frame Adaptive Modulation (mode header + auto-detect) — Results (2026-07-08)

**Component:** `trios-mesh` `src/modem.rs`, `examples/mcs_auto_link.rs`
**Commit:** `6349cc1`
**Goal:** turn the iter15 adaptive-MCS engine from ADVISORY (log a recommendation)
into ACTUAL per-frame modulation switching the receiver can follow.

## What was built

- **Mode header on the wire:** `tx_shaped_auto(payload, qpsk)` frames as
  `[Barker preamble][BPSK mode byte][length+payload in that modulation]`. The mode
  byte always rides BPSK, so the receiver reads it before the body — **no global
  mode agreement needed** (different frames can use different modulations).
- **Auto-detect receiver:** `rx_recover_auto → (payload, was_qpsk)` syncs on the
  Barker, reads the BPSK mode byte, then demods the body in the signaled mode
  (BPSK sign path or QPSK phase-tracked path). The ω refine runs over the
  pilot+mode header (both BPSK); the per-mode payload phase tracker is applied
  after the header. The fixed BPSK/QPSK/16-QAM paths are untouched (zero regression).

## Demonstrated (`mcs_auto_link`, time-varying link good → marginal → good, 1000 frames)

The sender measures link SNR, `pick_mcs` chooses BPSK/QPSK per frame, signals it,
and the receiver auto-detects:

| metric | result |
|--------|--------|
| frames delivered | **1000/1000 (100%)** |
| rate-weighted goodput | **1780** (vs 1000 all-BPSK) — 1.78× |
| sender chose QPSK | 780/1000 (on the clean stretches) |
| receiver mode-detect correct | **1000/1000** |
| mis-detected modes | **0** |

So the sender adapts BPSK↔QPSK per frame by link quality and the receiver just
follows — the adaptive-MCS loop is closed from advisory to real switching.

## What remains (needs boards)

The only missing piece is the **over-air SNR feedback**: the RECEIVER measures the
link SNR (already done, iter11) and reports it to the SENDER (e.g. piggybacked on
HELLO), so the sender adapts based on the *far end's* view. In this host sim the
sender measures SNR directly off a probe; wiring receiver→sender feedback + running
it on 2 boards is the deployment step. The hard parts — per-frame switching and
auto-detect — are done and host-verified.

Also: the mode header carries 2 modulations (BPSK/QPSK); FEC and RS are separate
opt-in layers. 16-QAM is excluded (ISI-limited, QAM16_ISI_FINDING).

## Reproduce

```
N=1000 cargo run --release --example mcs_auto_link
cargo test auto_receiver
```
