# Multi-Block RS Key-Frame Protection — Results (2026-07-08)

**Component:** `trios-mesh` `src/vstream.rs`, `examples/video_stream_over_radio.rs`
**Commit:** `c9d2228`
**Goal:** close the iter13 known-limit — a key frame larger than one GF(256) RS
block (~>11 KB) fell back to unprotected best-effort. Support ARBITRARY key-frame
sizes (480p/720p IDRs are hundreds of fragments).

## What changed

A large key frame is now split into **multiple independent RS blocks** (≤128 data
fragments each, so `K_b + M_b ≤ 256` for any parity), each MDS-protected. The
frame is whole once **every** block reconstructs.

- Wire (RS fragment) extended: `[VSTREAM][seq:2][idx][count][flags][block][nblocks][k][blk_len:2][data]` (11-byte header).
- `fragment_frame_rs(seq, data, parity_pct)` multi-blocks internally.
- `Playout` reassembles each block by RS, then concatenates blocks in order.
- `Asm` refactored to an enum (`Plain` best-effort | `Rs(Vec<block>)`).
- `parse_fragment` rejects corrupt headers (`k=0` / `k>count` / `block>=nblocks` / `nblocks=0`).

## Measured (`video_stream_over_radio`)

**21 KB key frame → 3 RS blocks (333 data fragments):**

| link | before (iter13) | now |
|------|-----------------|-----|
| clean | best-effort fallback (unprotected) | **byte-identical** |
| 20% drop, 40% parity | (lost) | **key delivered** |

**Small clip (2.5 KB, 1 block):** no regression, still byte-identical, key
survives 30% at 40% parity.

## Honest property — multi-block needs more parity

A multi-block key frame needs **ALL** its blocks, so end-to-end survival ≈
`(per-block survival)^B`. A larger key frame is therefore inherently more
vulnerable at a given loss and needs **higher parity**:

| 21 KB key frame @ 30% drop | key delivered |
|---------------------------:|:-------------:|
| RSPAR 40% | ❌ |
| RSPAR 60% | ✅ |
| RSPAR 80% | ✅ |

(A single 2.5 KB block survives 30% at 40% parity.) The efficient future upgrade
is **cross-block interleaving** (spread each block's fragments so a burst hits all
blocks evenly) or a per-frame parity budget sized to `B` — noted, not yet built.

## Scope

Host simulation, transport + modem layer. `RS_BLOCK_MAX=128`, `RSFRAG=64` →
`nblocks ≤ 255` covers key frames up to ~2 MB (far beyond any real IDR). Remaining
Channel V work: 2-board over-air measurement, live encoder pipeline, cross-block
interleaving for parity efficiency.

## Reproduce

```
# a clip with a large (multi-block) key frame:
ffmpeg -f lavfi -i "testsrc2=duration=0.4:size=640x480:rate=10" -c:v libx264 \
  -b:v 3000k -g 30 -preset fast big.mp4
ffmpeg -i big.mp4 -c:v copy -bsf:v h264_mp4toannexb -f h264 big.h264   # ~21 KB key frame
MOD=qpsk DROP=0  RSPAR=40 cargo run --release --example video_stream_over_radio big.h264 out.h264  # byte-identical
MOD=qpsk DROP=30 RSPAR=60 cargo run --release --example video_stream_over_radio big.h264           # key survives
cargo test vstream    # incl. rs_multiblock_large_keyframe_survives_per_block_loss
```
