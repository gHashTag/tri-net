# 16-QAM — Honest Finding: ISI-Limited, Not Viable on This Modem (2026-07-08)

**Component:** `trios-mesh` `src/modem.rs`, `examples/qam16_isi_floor.rs`
**Commit:** `f47d2d8`
**Goal (attempted):** the 4th modulation rung — 16-QAM, 4 bits/symbol = 4× BPSK
throughput — to lift the throughput ceiling (the #1 skeptic weakness).

## Result: an honest negative (like the iter8 net-negative FEC finding)

**16-QAM is NOT viable on the current feedforward modem.** The constellation and
carrier demodulation are correct; the modem's residual ISI corrupts it.

## The two facts

1. **The 16-QAM core is correct.** At the symbol level (perfect timing, unit
   amplitude, no pulse-shaping), all 256 byte values round-trip byte-exact
   (`qam16_symbol_core_is_exact`). Gray-mapped two-axis 4-PAM, 1/√10 unit-energy,
   pilot-derived amplitude reference, reduced-constellation (corner-only) DD
   carrier loop — all standard and verified.

2. **The modem can't carry it.** Through `tx_shaped → rx_recover` on a **perfectly
   clean channel** (no noise, no CFO):

   | modulation | clean-channel FER |
   |------------|------------------:|
   | QPSK | **0.0%** |
   | 16-QAM | **46.6%** |

## Root cause

BPSK/QPSK decide on **sign** — a symbol at ±1 with the threshold at 0 has a full
unit of margin, so the modem's residual timing/pulse-shaping ISI never flips it.
16-QAM decides on **amplitude** — 4 levels {−3,−1,+1,+3} with thresholds only one
level apart — so the *same* residual ISI (invisible to sign decisions) pushes
symbols across their tight thresholds and corrupts the frame. It is a **timing/ISI
precision** problem, not a noise problem (this is a clean channel).

## Conclusion & roadmap implication

- **The reliable PHY ceiling on this modem is QPSK** (2× BPSK). Adaptive MCS tops
  out there; 16-QAM is left EXPERIMENTAL, not wired into the daemon or MCS.
- Robust 16-QAM needs a **symbol-timing loop** (e.g. Gardner TED) + an
  **equalizer** + decision-directed amplitude tracking. That level of DSP belongs
  with the **PL/FPGA-offload / OFDM** path (W6), not the host feedforward modem.
- So the throughput roadmap is: QPSK (done) → **PL modem + OFDM/QAM** (hardware),
  not another host modulation rung. This is the useful thing the attempt taught us.

## Reproduce

```
N=2000 cargo run --release --example qam16_isi_floor   # QPSK 0% vs 16-QAM ~47%
cargo test qam16_symbol_core                           # core is byte-exact
```
