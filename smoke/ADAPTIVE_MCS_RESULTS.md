# Adaptive Modulation & Coding (MCS) — Results (2026-07-08)

**Component:** `trios-mesh` `src/mcs.rs`, `examples/mcs_calibrate.rs`, `examples/mcs_adaptive.rs`, `src/bin/trios_radiod.rs`
**Commits:** `dfff2ec` (engine + sim), `a62cf99` (daemon advisory)
**Goal:** tie iters 9–14 together — use the per-frame SNR estimate to pick the
fastest sustainable rate, turning the fixed-rate radio into a link-adaptive one.
This is what separates a real MANET radio from Meshtastic's fixed rate.

## The engine — `mcs.rs`

`pick_mcs(snr_db, current) -> Mcs` over three profiles: **BPSK+FEC** (0.5×, most
robust) / **BPSK** (1×) / **QPSK** (2×).
- **Threshold table** on the data-aided SNR estimate, with **hysteresis**
  (step-up thresholds above step-down) so a dithering estimate can't flap.
- **Step DOWN promptly** (protect delivery), **step UP conservatively** (avoid the
  one-lucky-frame probe trap).
- `ewma(α≈0.2)` smooths the estimate before the decision.
- Matches the rate-adaptation literature (SNR-threshold + EWMA + 2–3 dB
  hysteresis, DVB-S2 / LTE-CQI style).

**Thresholds calibrated from measurement** (`mcs_calibrate`):

| est-SNR | BPSK+FEC | BPSK | QPSK |
|--------:|---------:|-----:|-----:|
| 17.9 dB | 0% | 0% | 0% |
| 14.7 dB | 0% | 0% | 2.9% |
| 10.4 dB | 0% | 0.2% | 77% |
| 8.9 dB | 0% | 4.0% | 98% |
| 7.5 dB | 0.3% | 30% | 100% |

→ QPSK reliable ≥ ~18 dB, BPSK ≥ ~10 dB, BPSK+FEC below (thresholds 18/16 and
11/9 with the hysteresis gap).

## The value — `mcs_adaptive` (time-varying link, good → near-dead → good, 1200 frames)

| strategy | goodput | delivered | eff-thruput (w/ retransmit) |
|----------|--------:|----------:|----------------------------:|
| fixed BPSK+FEC | 600 | 100% | 0.50 |
| fixed BPSK | 1182 | 98% | 0.97 |
| fixed QPSK | 1432 | **60%** | 0.85 |
| **ADAPTIVE** | **1320** | **100%** | **1.10** |

- **Adaptive delivers every frame at +12% goodput over the best reliable fixed
  strategy**, and the **highest effective-throughput** (1.10 vs 0.97) once lost
  frames are honestly charged their airtime + retransmit.
- Fixed QPSK's higher raw goodput (1432) comes from **dropping 40% of frames** —
  unusable for a stream.
- Only **5 mode switches** over 1200 frames — hysteresis working (no flapping).

## Hardware (board 11, real AD9361 self-echo, 16 s)

The daemon EWMA-smooths the measured link SNR and logs the sustainable mode:

```
[radiod] rx burst … src=11 SNR~18.2dB (link~18.2dB -> MCS QPSK *switch*)
… link 18.2–18.5 dB -> MCS QPSK (84 advisories, 0 panics)
```

The adaptive decision runs **live on real hardware**: real IQ → SNR estimate →
EWMA → `pick_mcs` → QPSK (the strong direct-coupling self-echo link sustains the
fast mode). First frame logs the BPSK→QPSK switch.

## Scope

Host + advisory. **Not yet:** over-wire per-neighbor SNR feedback (receiver →
sender) + per-frame mode signaling to actually switch modulation on a live 2-board
link (the deployment step), and a NACK/loss outer-loop (LTE-OLLA style) to correct
a biased SNR estimate. The engine, calibration, value, and on-hardware decision
are proven.

## Reproduce

```
N=3000 cargo run --release --example mcs_calibrate     # threshold calibration
N=1200 cargo run --release --example mcs_adaptive       # adaptive vs fixed
cargo test mcs                                          # engine (hysteresis, EWMA)
# on a node: trios_radiod logs `link~X.XdB -> MCS <mode>` per BPSK frame
```
