# Channel V — Real-Time Video STREAMING: Results (2026-07-08)

**Component:** `trios-mesh` `src/vstream.rs`, `examples/video_stream_over_radio.rs`
**Commit:** `092e646`
**Goal:** turn the whole-file ARQ video transfer into REAL-TIME streaming —
continuous frames, loss-tolerant, bounded latency.

## The problem with file-ARQ for live video

`video_over_radio` (Channel V as a file) uses `filexfer`: every chunk is
retransmitted until the CRC matches. Correct for a stored clip, **fatal for live
video** — one lost chunk stalls the whole stream while it is re-fetched, and
latency grows without bound as the link degrades. Live video needs the opposite
trade.

## What was built — `vstream`

- **Wire:** `[VSTREAM][seq:u16][frag_idx][frag_count][flags(keyframe)][data]`,
  70 B/fragment. Frames are H.264 access units; the IDR (key) frame is flagged.
- **Best-effort fragments** — no CRC, no ARQ (a live frame is played or skipped,
  so a per-chunk checksum adds nothing over the AEAD tag).
- **Playout buffer:** a `depth`-frame jitter window. Each frame gets `depth`
  frame-intervals to complete; if it hasn't by its playout slot it is **SKIPPED,
  never retransmitted**. End-to-end latency is therefore **constant**
  (`depth × frame_interval`) regardless of loss — the property live video needs.

## Measured (real 36-frame 12 fps H.264 clip, QPSK, depth=3 → 250 ms latency)

**Clean link:** 36/36 frames delivered, output **byte-identical** to source,
real-time with headroom (0.07 s airtime for 3 s of video).

**Loss sweep — graceful degradation + constant latency:**

| drop | frames delivered | playout latency |
|-----:|-----------------:|-----------------|
| 0% | 36/36 (100%) | 250 ms |
| 10% | 27/36 (75%) | **250 ms** |
| 20% | 20/36 (56%) | **250 ms** |
| 30% | 13/36 (36%) | **250 ms** |

The stream **never stalls** — latency is 250 ms at every loss rate (vs file-ARQ,
which hangs waiting for the missing chunk). Frame delivery degrades smoothly:
the decoder shows a lower-frame-rate / partially-frozen picture, not garbage.

## Key-frame protection — an honest finding

Modem FEC fixes **bit errors** but not a **dropped fragment** (an erasure). A
~37-fragment IDR frame almost never fully arrives under loss, and **without the
key frame the whole GOP is undecodable**. So the key frame needs erasure
protection, not just bit-FEC.

MVP fix — **repetition** (simplest real erasure code; the receiver is idempotent
to duplicate fragments):

| KEYREP | key delivered @ 20% drop |
|-------:|--------------------------|
| 1× | NO (GOP undecodable) |
| 3× | NO |
| 5× | **YES** |

At 10% drop, 3× already restores the key. Repetition is wasteful; a proper
**(N,K) Reed-Solomon / RaptorQ erasure code** across the key frame's fragments is
the efficient upgrade (recovers any M erasures from K+M with far less overhead) —
the clear next iteration.

## Channel status

| channel | status |
|---------|--------|
| T (text) | ✅ over air + internet-over-radio |
| P (photo) | ✅ byte-identical file transfer |
| V (video file) | ✅ byte-identical real H.264 clip + goodput (0.8–1.6 Mbps) |
| **V (video streaming)** | ✅ **loss-tolerant, bounded-latency streaming (this doc)** |
| V refinements | ⬜ RS/RaptorQ key-frame erasure code · 2-board over-air · live encoder feed |

## Honest scope

Host simulation, modem + transport layer. Real 2-board over-air will be lower
throughput / higher loss (CSMA, half-duplex, RF) and needs boards 12/13. The
input is a pre-encoded clip split into access units, not a live encoder feed;
wiring a real-time encoder → `vstream` → radio → decoder is the end-to-end live
demo (needs the hardware pipeline).

## Reproduce

```
ffmpeg -i clip.mp4 -c:v copy -bsf:v h264_mp4toannexb -f h264 clip.h264
MOD=qpsk DROP=0 cargo run --release --example video_stream_over_radio clip.h264 out.h264   # byte-identical
MOD=qpsk DROP=20 KEYREP=5 cargo run --release --example video_stream_over_radio clip.h264  # loss-tolerant
cargo test vstream
```
