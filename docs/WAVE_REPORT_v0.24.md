# Wave v0.24 — adaptive ceiling, audio on the express port, and the collision that was waiting

All three tracks. The most important thing this wave shipped is invisible: a
latent bug that would have fired the moment track 1 went live.

## The seq collision (found by arithmetic, not luck)

The express (audio) path and the video uplink each keep their own seq counter —
and the peer reassembles **both from one map keyed by seq alone**. At real call
rates (~44 video NALs/s, ~50 audio frames/s) the two counters advance almost in
step, so equal seqs coexist within the reassembly GC window and **splice
fragments of different payloads together**: corrupt NALs, vanished audio.

Why v0.19's express verification missed it: that test ran video at 20 NAL/s and
audio at 50/s, so same-seq arrivals were >3s apart — outside the 2s GC window.
The bug was real, latent, and scheduled to fire exactly when audio moved to the
express port at call rates. The u16 seq space is now partitioned in the spec:
video owns 0..32767, express owns 32768..65535. Same wire format, disjoint keys.

## Track 2: the adaptive ceiling

`FRAG_RATE_PER_SEC` was the last configured guess in the control loop. A radio's
capacity moves with range and fading; a typed-in 800 cannot.

**Capacity below saturation is unmeasurable — but a saturated link states its
own capacity: it is what actually arrives.** Each node now tells its peer, once
a second on the mesh port, how many fragments it received:

```
[RX_REPORT_TYPE][cnt_lo][cnt_hi]     (plaintext counters, no content, ever)
```

The sender steers the encoder against `fb_effective_rate`: a fresh lossless
report (>=90% delivered) or no report at all means "trust the configured
ceiling"; a fresh lossy report means the link has spoken — the ceiling becomes
what got through.

Verified against the deployed node with a **lying peer** (.12 stopped, the Mac
forging rx-reports):

| peer's claim | advertised ceiling |
|---|---|
| honest (delivered = sent) | 700, 700, 700, 700 |
| **lying (delivered = 200)** | **200, 200, 200, 200** |
| honest again | 700, 700, 700, 700 |

The whole chain now follows a moving link: delivered drops -> ceiling drops ->
advice -> AIMD slims the encoder. When a radio fades, video thins out **by
itself**. Nothing in the loop is a guess anymore.

## Track 1: audio on the express port

Both apps now send audio to `AUDIO_IN_PORT` (7002): its own budget, never paced,
no parity duplicate. On the video port every audio packet cost **two** fragments
(a parity over one fragment IS a copy) — 100 frags/s of a 700/s budget, half of
it duplicates, plus the measured p50 182ms head-of-line delay behind keyframes.

Same sealing, different door — and only when a node has proven itself with a
fresh feedback report. A direct call has no node and the peer listens on the
main port alone, so audio falls back to the normal path automatically. Group
mode unchanged.

## Track 3: radio

`.11` no radio, `.12` has one, `.13` unreachable. One radio, as in every wave.

## Verification, through a live call

The iPhone kept streaming through the mesh during the entire wave, which turned
the regression suite into something better: **7/7 end-to-end and 6/6 exact-loss
with real traffic sharing the nodes.** Two false alarms on the way, both mine:

- The first regression run returned 0/7 with healthy daemons. Cause one: I
  redeployed `.12` without its pinned device — 84 payloads honestly logged as
  `DISCARDED: no device attached`. Cause two: the probes listened on 7001 while
  the production nodes deliver to 7000, and their single `recv()` grabbed
  whatever arrived first — usually someone's audio frame. The probes now take a
  delivery port and skip foreign datagrams until theirs arrives or the deadline
  passes. A shared mesh means the harness must expect company.

17/17 wire tests. Both apps rebuilt and installed. Commit `ad76995`.

## Honest status

Every constant in the congestion path is now either measured or self-adapting:
admission is size-blind, sending is paced, loss is repaired interleaved, audio
has its own door, the encoder obeys the node, and the node's ceiling obeys the
link. The software stack for "видео связь в полях" is complete **and closed
loop**. What does not exist is still the field part: one radio, no link. That is
hands — cold-cycle `.11` on dedicated power, bring `.13` back — not code.

## Three options for the next wave

### 1. Restart the call and watch the new plumbing (a minute of your hands)
Audio should appear in the nodes' `[audio]` counters (express class) instead of
the video TX log, video should gain ~14% of budget, and the whole thing should
still converge to zero drops. One Start on each device.

### 2. Multi-hop: three nodes in a chain (software, needs .13 back OR runs 2-hop)
Everything so far is device-node-node-device. The mesh's promise is N hops. The
bridge already relays blindly, but the rx-report/effective-rate chain is
pairwise — a 3-node chain would show whether backpressure propagates end to end
or needs per-hop aggregation. Testable today with 2 hops + the Mac playing a
third node.

### 3. The radio (blocked on you, unchanged)
Cold cycle `.11` on dedicated power; bring `.13` back onto the network. The
entire control stack above is built, measured, and waiting for it.

**Recommendation: 1, then 3.** Option 1 confirms this wave on the product in a
minute. After that, the single highest-value action for the whole project is
physical: a second radio. The software has been ready for it since v0.18; now
even its control loop is.
