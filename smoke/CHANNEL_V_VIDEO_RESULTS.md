# Channel V — Video: Results (2026-07-08)

**Component:** `trios-mesh` `examples/video_over_radio.rs` (+ `filexfer`, `modem`, `fec`)
**Commit:** `1d42e37`
**Question answered:** "что у нас с передачей видео?" — can we transmit video, and at what quality?

## Short answer

**Video as a FILE works today** — a real H.264 clip goes through the full radio
stack byte-identical — and there is **1–2 orders of magnitude of throughput
headroom** over the clip's own bitrate, so even low-res real-time streaming is
plausible. What's not yet done: a real **2-board over-air** transfer (needs boards
12/13) and a **streaming** mode (continuous loss-tolerant frames vs whole-file ARQ).

## What was demonstrated

A real **3-second 160×120 H.264 clip (13,755 bytes, ~37 kbps)** pushed through the
entire stack on the host: fragment → [FEC] → BPSK/QPSK modem → noisy + lossy
channel → demod → [FEC] → NACK-driven ARQ reassembly → CRC-32. Output is
**md5-identical** to the input and still a **valid, playable .mp4** (ffprobe: h264
160×120 3.0 s). Video is just a bigger file; the Channel P transport is
byte-agnostic, so it carries video unchanged.

## Measured modem-layer goodput (host sim, AD9361 4 MSPS → 1 Msym/s)

| profile | link | effective goodput | ARQ rounds |
|---------|------|------------------:|-----------:|
| BPSK | σ=0.15, 8% drop | **~830 kbps** | 4 |
| QPSK | σ=0.15, 8% drop | **~1.6 Mbps** | 3 |
| QPSK+FEC | σ=0.28, 18% drop (marginal) | **~710 kbps** | 4 |

- QPSK delivers ~2× BPSK, as expected.
- On a marginal link, QPSK+FEC still delivers ~0.7 Mbps reliably.
- The clip needs **~37 kbps** → **20–40× headroom**. Real-time streaming feasible:
  YES at the modem layer.

## Feasibility ladder (what these numbers imply)

| video | bitrate | vs measured goodput |
|-------|--------:|---------------------|
| this clip (160×120, 12 fps) | ~37 kbps | ✅ trivially |
| 240p H.264 | ~150–300 kbps | ✅ comfortable |
| 480p H.264 | ~0.5–1 Mbps | ✅ BPSK marginal, QPSK OK |
| 720p H.264 | ~1.5–3 Mbps | ⚠️ QPSK edge; needs 16-QAM/OFDM |

## Honest scope — what these numbers are NOT

- **Host simulation, modem layer.** The real 2-board **over-air** goodput will be
  **lower**: CSMA backoff, half-duplex turnaround, real RF impairments, and the
  ARM's continuous-stream limits all subtract. Needs boards 12/13 to measure.
- **File transfer, not streaming.** This uses whole-file ARQ (every chunk retried
  until the CRC matches) — correct for a stored clip, wrong for live video. A
  streaming Channel V wants continuous, loss-tolerant frames (drop late frames,
  no infinite retransmit) + codec framing. That layer is not built yet.

## Where Channel V stands

| channel | status |
|---------|--------|
| T (text) | ✅ proven over air (+ internet-over-radio) |
| P (photo) | ✅ byte-identical file transfer proven |
| **V (video file)** | ✅ **byte-identical real H.264 clip through the stack + goodput measured (this doc)** |
| V (video streaming) | ⬜ streaming/codec layer + 2-board over-air = remaining work |

Everything from iters 9–11 feeds this: the phase tracker (iter9) removed the
frame-length penalty that hurt long transfers, QPSK (iter10) doubled throughput,
FEC-now-net-positive (iter9) makes marginal links reliable, and the SNR estimator
(iter11) is what a future adaptive-rate streamer would use to pick quality.

## Reproduce

```
ffmpeg -f lavfi -i testsrc=duration=3:size=160x120:rate=12 -c:v libx264 -b:v 80k clip.mp4
MOD=qpsk cargo run --release --example video_over_radio clip.mp4 out.mp4
MOD=qpsk FEC=1 SIGMA=0.28 DROP=18 cargo run --release --example video_over_radio clip.mp4 out.mp4
```
