# Wave v0.19 — sustained load, an express class, and a real call across the mesh

Two things happened. The planned work (measure sustained load) found a real
defect and fixed it. Then, mid-wave, the probes "broke" — and the reason was that
**a real call had started flowing through the mesh**.

## The real call

`bridge_probe` returned 0/7 and the FEC suite 0/6, immediately after both had
passed. The daemons were alive. The logs said why:

```
.11: TX 1234B -> 18 frags + 2 parity  from 192.168.1.105:7000   <- the Mac
.12: TX  905B -> 13 frags + 1 parity  from 192.168.1.103:7000   <- 192.168.1.103
```

Not the probes. `192.168.1.103` answers with a private MAC (`a6:87:63:db:d3:7`)
and `TriNetMonitor` was live on UDP `*:7000`. Someone had typed the node IPs into
both apps. **The probes had not broken; they were colliding with a real
bidirectional call.**

Both directions were already relaying — 44 NAL/s from the Mac, 83 NAL/s from the
phone — but this wave's restarts had dropped `VIDEO_OUT_PORT=7000`, so reassembled
payloads went to port 7001 where only the probe listened. The apps were sending
into the mesh and receiving nothing back.

With the delivery port corrected:

```
.11 -> 192.168.1.105:7000    (iPhone -> mesh -> Mac)
.12 -> 192.168.1.103:7000    (Mac -> mesh -> iPhone)
```

First measurement of the live call, at the default 800 frags/s ceiling:

| | Mac side (.11) | iPhone side (.12) |
|---|---:|---:|
| NALs into the mesh | 1337 | 2376 |
| NALs delivered to device | 2359 | 1346 |
| **dropped, budget full** | **1055 (44%)** | 0 |

The Mac's encoder offered ~2700 frags/s against a 700 frags/s video budget and
**44% of its packets were dropped**. But 800 frags/s is a **guess about a radio
that is not in this path** — the traffic crosses Ethernet, and v0.16 measured the
node at 8000 frags/s. Raising the ceiling to 4000 (half the measured limit):

| | Mac side | iPhone side |
|---|---:|---:|
| NALs into the mesh | 1707 | 1147 |
| NALs dropped | **0** | **0** |
| NALs delivered to device | 1134 | 1738 |

Counts cross-match (1707 sent -> 1738 delivered; 1147 -> 1134). **A real,
bidirectional, end-to-end-encrypted video call crossing two mesh nodes with zero
loss.** Everything the last five waves built — port demux, size-blind admission,
pacing, FEC, interleaving — was carrying live traffic.

Two things the live call confirmed that no probe could:
- **Max payload 1235B.** The apps fragment at 1200B, so the bridge never sees a
  whole I-frame — the double-fragmentation predicted in v0.15, now observed.
- **Audio and video share port 7000.** The apps do not know about the express
  class yet, so the live call still has the head-of-line problem below.

## The planned work: sustained load

Every prior test sent ONE NAL and waited. Real video never does. Realistic 30fps,
2000B P-frames, 9000B IDR every 2s:

| offered | delivered | p50 latency |
|---|---:|---:|
| ~660 frags/s (under the ceiling) | **100%** | 92ms |
| ~960 frags/s (over the ceiling) | 89% | 249ms |

The bridge behaves correctly under overload: latency stays **bounded** (226ms ->
253ms across the run — no runaway queue), and the drops are **unbiased by size**:
33 of 313 P-frames and 1 of 6 IDR, proportional to frequency. v0.15's size-blind
admission holds under real load.

## The defect: audio queues behind keyframes

A call sends audio through the same bridge — 63B Opus frames every 20ms, one
fragment each. A 138-fragment keyframe takes 172ms to pace, and audio behind it
waits for all 138:

```
audio, no keyframe in flight: p50 =  84ms
audio, KEYFRAME in flight   : p50 = 182ms, max 270ms
```

Audio tolerates ~30ms of jitter. That is an audible dropout every time a keyframe
goes by.

**The node cannot fix this by looking.** Both streams are sealed end-to-end and it
must never try to read them. So the app declares the class by **choosing a port** —
the same principle that replaced the magic byte. `AUDIO_IN_PORT` (7002) gets its
own socket, its own thread, and its own budget. It is **never paced**, because
waiting is the entire problem. The budgets **sum** to the ceiling (video pays 12%
of its rate), so priority can never over-commit the link.

```
audio, no keyframe in flight: p50 = 3ms
audio, KEYFRAME in flight   : p50 = 3ms, max 118ms
```

The coupling is gone — both rows identical. p50 84ms -> 3ms, and 182ms -> 3ms
while a keyframe is in flight.

## A phantom regression I nearly reported

The first express run showed 438 audio frames delivered against 501 before, and I
started writing it up as a delivery regression. It was not: the harness offered
491, not 600 — Python's `time.sleep` cannot hold 50Hz, so the sender was slower
than I had assumed. Delivery was 491/491 = **100%**. Fourth instrument to lie this
session, and this one was mine. Counting what you *assume* was offered instead of
what was *actually* offered is the same error as reading a counter that does not
exist.

## Verification

15/15 wire tests (the port-distinctness guard now covers `AUDIO_IN_PORT`), the
FEC exact-loss suite, and the end-to-end probe all pass. Commit `83f4895`.

## C — radio, unchanged

`.11` no radio, `.12` has one, `.13` unreachable. The live call crosses two nodes
over **Ethernet**. The radio still has never carried a byte.

## Honest status

**The product now runs over the mesh.** That is a genuine milestone and it is the
first time it can be said. What it is not: a radio link. The nodes are relaying
over Ethernet, and the 4000 frags/s that made the call lossless is ~8x what the
480 kbps radio budget would allow. When a radio appears, the encoder must fit
480 kbps or the 44% drop rate comes straight back.

## Three options for the next wave

### 1. Teach the app the express class (unblocked, small)
The live call still sends audio and video to one port, so it still has the
head-of-line problem the bridge is now equipped to solve. `AudioController` sends
its Opus frames to `node:7002` instead of `node:7000` — one destination change on
each platform. The bridge side is built and measured.

### 2. Close the backpressure loop (unblocked, the real gap)
The Mac dropped 44% of its packets and **nothing told it**. The app's adaptive
bitrate reacts to PLI — decoder feedback, which only arrives after frames are
already corrupt. The bridge knows its drop rate exactly and has no way to say so.
Until that loop closes, every link-capacity change is discovered the hard way.

### 3. The radio (blocked on you, unchanged)
Cold cycle `.11` on dedicated power; bring `.13` back. Now more valuable than
before: there is a real call to put on it.

**Recommendation: 2.** Option 1 is a nice win but the call already works without
it; option 2 is what stands between "works on a bench with a hand-tuned rate" and
"works on a link whose capacity nobody typed in".
