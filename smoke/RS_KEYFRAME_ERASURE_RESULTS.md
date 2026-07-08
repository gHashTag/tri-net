# Reed-Solomon Key-Frame Erasure Code — Results (2026-07-08)

**Component:** `trios-mesh` `src/rs.rs`, `src/vstream.rs`, `examples/video_stream_over_radio.rs`
**Commit:** `b98aab6`
**Goal:** close the one remaining Channel-V streaming weakness (iter12) — protect
the video key frame against fragment LOSS with a real erasure code instead of the
repetition stopgap.

## The problem (from iter12)

Modem FEC fixes bit errors but not a **dropped fragment** — that is an *erasure*.
A ~37-fragment IDR key frame almost never fully arrives under loss, and without it
the whole GOP is undecodable. Repetition (send each key fragment 3–5×) worked but
was wasteful and still lost the key at 20% drop.

## What was built — `rs.rs`

Systematic **Reed-Solomon over GF(256), Cauchy generator**:
- GF(256), primitive poly `0x11d`, doubled exp table (no modulo), `mul` guards 0
  — the classic pitfalls, checked by a field-axiom test (`a·inv(a)=1 ∀a`).
- Cauchy matrix `G[i][j] = 1/(x_i ⊕ y_j)`, `{x_i}={0..M}` disjoint from
  `{y_j}={M..M+K}` → **provably MDS**: ANY K of the K+M coded fragments
  reconstruct the frame (`K+M ≤ 256`). Decode inverts the K×K received submatrix
  over GF.
- Tests: field axioms; recovers **every** random size-M erasure pattern for
  `(k,m) ∈ {(4,2),(10,4),(37,10),(8,8)}`; no-loss identity; `<K` → `None`.

Wired into `vstream`: `FLAG_RS` + `fragment_frame_rs(seq, data, m)` (pad to K
`RSFRAG=64` fragments, add M parity, carry `k`+true length); `Playout`
RS-decodes a key frame as soon as ANY K fragments arrive. P-frames stay plain
best-effort.

## Measured (37-fragment key frame, QPSK)

**Clean link:** 36/36 frames, output byte-identical.

**Key-frame survival vs loss (RSPAR = parity as % of K):**

| drop | repetition 3× (iter12) | RS 40% parity (this) |
|-----:|:----------------------:|:--------------------:|
| 10% | ✅ | ✅ |
| 20% | ❌ lost | ✅ |
| 30% | ❌ lost | ✅ |

**Parity sizing (at 30% drop) — matches theory** (survive loss `p` needs
`M ≳ K·p + margin`):

| RSPAR | key delivered @ 30% |
|------:|:-------------------:|
| 10% | ❌ |
| 25% | ❌ |
| 40% | ✅ |
| 60% | ✅ |

**Overhead — the MDS win:**

| scheme | key-frame air | protection |
|--------|:-------------:|------------|
| repetition 3× | 3.0 × K | lost key at 20% |
| **RS 40% parity** | **1.4 × K** | **key survives to ~28%** |

MDS gives **better protection at less than half the overhead** — M parity buys
exactly M erasures, no waste. This is the efficient, correct tool the iter12
finding called for.

## Honest scope

Host simulation, transport + modem layer. Still to do for a full live Channel V:
2-board over-air measurement (needs boards 12/13), and a live encoder → `vstream`
→ radio → decoder pipeline. P-frames remain best-effort (correct — a lost P-frame
is a transient glitch, only the reference key frame needs MDS protection).

## Reproduce

```
MOD=qpsk DROP=0 RSPAR=40 cargo run --release --example video_stream_over_radio clip.h264 out.h264   # byte-identical
MOD=qpsk DROP=30 RSPAR=40 cargo run --release --example video_stream_over_radio clip.h264            # key survives
cargo test rs::            # erasure-code correctness
cargo test vstream         # incl. RS key-frame survival
```
