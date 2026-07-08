# Per-Frame SNR / Link-Quality Estimator — Results

**Date:** 2026-07-08
**Component:** `trios-mesh` `src/modem.rs` (`rx_recover_snr`), `src/bin/trios_radiod.rs`, `examples/snr_curve.rs`
**Commit:** `40fcddf`
**Goal:** give the modem a per-frame link-quality number — the "link budget /
range curve" a skeptical RF engineer asks for (competitor-ranked weak point #3),
and the prerequisite instrument for adaptive modulation.

## Why this, not C′ this iteration — a hard environmental finding

C′ (TUN + NAT → real ping/curl) was the planned target, but the board kernel
**cannot support it**:

```
$ cat /proc/config.gz | zcat | grep CONFIG_TUN
# CONFIG_TUN is not set
```

No `/dev/net/tun`, no `tun.ko`, no `/lib/modules`, no `iptables`, `ip_forward=0`.
Creating the device node by hand (`mknod /dev/net/tun c 10 200`) does nothing —
the kernel has no TUN driver registered (no misc device 200 after mknod).
**C′ requires a PetaLinux kernel rebuild with `CONFIG_TUN=y` (+ netfilter/NAT)** —
a hardware/build task in the same class as the FPGA/Vivado blocker (W6), not
something the daemon code can provide. Checking the environment first (doctrine:
observability before building) avoided writing TUN plumbing that could never run.

So this iteration delivered the fully host- and hardware-verifiable SNR estimator
instead. C′ is deferred to a kernel rebuild.

## What was built

`rx_recover_snr(iq) -> Option<(bytes, snr_db)>` — recover the frame AND estimate
the link SNR. Exposed per BPSK frame in the daemon RX log
(`rx burst … src=N SNR~X.XdB`).

**Method — data-aided, and why:**
- EVM measured on the **known Barker preamble, before** the decision-directed
  phase tracker. The tracker rotates each symbol onto its nearest constellation
  point, erasing the very residual error EVM should catch — so a payload/decision
  estimate reads optimistically (worst near threshold, where decisions are also
  wrong). The known pilot avoids both biases. `N/(N-2)` DoF correction unbiases
  the 2-parameter (ω, θ) pilot fit.
- **Scale-invariant:** signal amplitude `A` estimated from the pilot,
  `SNR = A² / noise`. Required because the RX front-end rescales each burst to a
  fixed peak, so symbols do not arrive at unit amplitude.

## Host validation — calibrated against the FER cliff (`snr_curve`, 90 B)

| channel σ | est. SNR (dB) | FER |
|-----------|--------------:|----:|
| 0.10 | 22.5 | 0.0% |
| 0.30 | 14.7 | 0.0% |
| 0.40 | 12.3 | 0.0% |
| 0.50 | 10.5 | 0.1% |
| 0.60 | 8.9 | 4.3% |
| 0.70 | 7.6 | 32.2% |
| 0.80 | 6.4 | 77.4% |
| 1.00 | 3.3 | 100% |

Monotonic and **calibrated**: the estimate tracks the FER cliff and matches the
BPSK link-budget anchors (references: ~6.8 dB Eb/N0 for BER 1e-3, ~9.6 for 1e-5,
+2 dB implementation loss → ~12 dB SNR reliable). 12 dB reads exactly at the 0%-FER
edge; frames start dropping below ~9 dB; the link is dead below ~5 dB. Per-frame
std ~0.5–1 dB (13-symbol data-aided estimate).

**Adaptive-MCS thresholds this hands us:** > ~14 dB → QPSK safe; ~10–14 dB → BPSK;
< ~9 dB → enable FEC or the link is failing.

## Hardware (board 11, real AD9361 self-echo, 16 s)

```
[radiod] rx burst 2491 -> frame 49B src=11 SNR~18.8dB
… mean 18.0 dB, range 17.5–18.8 dB, n=79, 0 panics
```

A sensible, tight number for a strong direct-coupling self-echo — ~6 dB above the
reliable-BPSK threshold, consistent with 79/79 clean decodes. **This is a real
link-budget datapoint measured off actual hardware over the air.**

**Broken-ruler caught here:** the first version assumed unit symbol amplitude and
read a nonsensical **−2.6 dB** on hardware while frames decoded perfectly — an
obvious contradiction (a −2.6 dB link can't decode 79/79). The cause was the
instrument, not the signal: the daemon peak-normalizes each burst so symbols
arrive at ~±1.25, not ±1. Amplitude-normalizing the estimate → 18 dB. Guarded by
a scale-invariance test.

## Reproduce

```
N=3000 LEN=90 cargo run --release --example snr_curve   # calibration curve
cargo test snr                                          # tracks-channel + scale-invariant
# on a node: trios_radiod logs `SNR~X.XdB` per BPSK frame
```
