# Over-Air SNR Feedback — Closes the Adaptive-MCS Loop (2026-07-08)

**Component:** `trios-mesh` `src/discovery.rs` (Hello), `examples/mcs_feedback_link.rs`
**Commit:** `10b30ed`
**Goal:** the last host-completable piece of adaptive MCS — the RECEIVER reports
the SNR at which it hears the SENDER, so the sender adapts to the FAR-END view of
the link (only the receiver knows how well it hears the sender).

## What was built

- **HELLO carries SNR (back-compatible):** after the `heard` list, an optional
  per-neighbor SNR block (quantized 0.2 dB/step). `Hello::with_snr(...)` sends it;
  `snr_of(me)` reads "the SNR at which `src` hears me". A HELLO without the block
  parses with an empty `snr`, so mixed old/new nodes interoperate.

## The full adaptive-MCS loop (now complete on the host)

```
receiver measures link SNR (iter11)  ->  reports it in HELLO (iter21)
   ->  sender adapts modulation to the far-end SNR (iter15 engine)
   ->  signals the mode in the frame header (iter20)  ->  receiver auto-detects (iter20)
```

## Demonstrated (`mcs_feedback_link`, A→B link good → dead-for-QPSK → good, 1000 frames)

B measures the SNR it hears A at and reports it every HELLO; A picks BPSK/QPSK for
frames→B from B's reported SNR:

| strategy | delivered |
|----------|----------:|
| **WITH SNR feedback** | **994/1000 (99%)** |
| stale belief (A never learns) | 805/1000 (80%) |

Through the deep fade, feedback lets A drop to BPSK (which survives) so frames keep
arriving; without feedback A keeps blasting QPSK into a link that can't carry it
and loses ~20% of frames. **The feedback is the mechanism that makes adaptation use
the *right* signal** — the receiver's actual link quality, not the sender's guess.

## Scope

Host simulation over two in-process nodes. A real 2-board run just swaps the
in-process HELLO for the radio HELLO (the daemon already beacons HELLO and now can
attach SNR). The daemon wiring (attach measured per-neighbor SNR to its HELLO,
maintain a far-end SNR table, feed `pick_mcs` per destination) is the small
remaining integration; the protocol + value are proven here.

## Reproduce

```
N=1000 HELLO=20 cargo run --release --example mcs_feedback_link
cargo test snr_report
```
