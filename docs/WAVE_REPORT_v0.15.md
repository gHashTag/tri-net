# Wave v0.15 — A, B, C in parallel

Three tracks were requested in parallel. A and B are done and proven on hardware.
C is unchanged and remains blocked on physical work this agent cannot do.

## A — the app/bridge seam: a magic byte cannot demux ciphertext

The seam turned out to be worse than "the bridge does not understand the app's
`0xFA 0xFB` fragments". The bridge is payload-agnostic and would have carried
them fine. The real defect is underneath:

The daemon ran **everything on port 7000** and told an attached device's payload
apart from a peer node's fragments by `buf[0] == VSTREAM_TYPE` (8). But the app
seals every datagram with ChaChaPoly, and `.combined` is `nonce||ciphertext||tag`
with a **random** nonce. The first wire byte is therefore uniformly distributed:

> **1 datagram in 256 starts with 0x08 and was swallowed as a mesh fragment.**

At the ~100 datagrams/sec a call produces, that is a corruption roughly **every
2.5 seconds, forever, at random**. A lost audio packet clicks; a lost video
fragment kills the entire NAL (reassembly is all-or-nothing) and freezes the
picture. It would have read as "the mesh is flaky" and no amount of staring at
the video code would have found it.

The comment in the app claims the magic is "unambiguous" because raw NALs start
`00 00 00 01`. That was true — and stopped being true the moment the channel was
encrypted. Nobody re-checked the claim.

**Fix:** demux by port, which the spec already prescribed and the daemon used
**zero times** (`MESH_PORT = 5000`, 0 references). Two sockets, two threads, no
byte sniffing:

```
device --(:7000)--> [node] --(:5000)--> [peer node] --(:7001)--> device
```

Also fixed while here: `dest` conflated "next mesh hop" with "where my device
is". That only works on a linear test rig — **a real node is both a relay and an
endpoint**. The device address is now learned from its ingress (it announces
itself by sending) and overridable by argv for a relay with no device of its own.

## B — the rate limiter dropped exactly the frames video cannot lose

`spent + nfrags > LIMIT -> drop` decides by **size**, so the biggest payload is
the one that never fits. In H.264 the biggest NAL is the **IDR keyframe** — the
one frame a decoder cannot resume without — while the small P-frames that
reference it sail through. It is also a trap: a PLI storm answers each dropped
IDR with another, bigger IDR.

Measured on the live node (the first two attempts to prove this **failed** —
see below):

```
TX   700B ->  10 frags  budget=680/800
DROP 9000B (129 frags)  budget=680/800   <-- 120 fragments were FREE
TX     60B ->   1 frags  budget=681/800   <-- passed 10ms later
```

The link was not full. The big payload was rejected **for being big**, and the
small one right behind it passed.

The bridge cannot tell an IDR from a P-frame anyway — the payload is sealed
end-to-end — so admission **must** be blind to size. Now: admit while the budget
is open, then let the count run into debt and pay it back next window. Same
experiment after the fix:

```
TX   9000B (129 frags)  budget=809/800   <-- keyframe survives
DROP   60B (1 frags)    budget=809/800   <-- the cheap frame pays
```

The ceiling still holds (peak 809 ~= 800; the overshoot is the debt).

`FRAG_RATE_PER_SEC` is now env-overridable and documented as a **guess** — the
radio's capacity has never been measured, because only one AD9361 has ever come
up at a time. It must be reconciled with a real link, not with arithmetic.

### Why this was invisible, and how two experiments failed first

Worth recording, because the failures were the useful part:

1. **Attempt 1** burned the budget with 690 tiny datagrams in 11ms. The node's
   UDP receive buffer ate 60% of them (the bridge read only 271), so the limiter
   never engaged.

   > **CORRECTION (v0.16).** This report originally added: *"Separate finding:
   > the node's rx buffer overflows under burst and nothing reports it."* That is
   > **false**. The kernel counts every one of these in `/proc/net/snmp` as
   > `Udp: RcvbufErrors`, and always has — the 420 drops from this very attempt
   > were sitting in that counter. Nothing was silent; I did not look. See
   > `WAVE_REPORT_v0.16.md`.
2. **Attempt 2** paced the burn — and the big NAL passed again. At that point the
   honest read was that I was trying to prove a claim about `frags_sent_this_sec`,
   **a counter printed nowhere**. The 1-second window rolls over on its own and I
   could not see its phase. That is the broken-ruler error, straight out of
   `SOUL.md` Art. VIII: I was measuring with an instrument that did not exist.
3. **Attempt 3** added the budget to every log line first. The bias fell out
   immediately and unambiguously.

The old code also printed drops only every 10th (`dropped_nals % 10 == 0`), so a
single dropped keyframe left **no trace at all**. Both defects were invisible by
construction, not by bad luck.

## C — second radio: unchanged, still blocked

Inventory taken this wave (`ad9361-phy` under `/sys/bus/iio/devices/`):

| board | ping | radio |
|---|---|---|
| 192.168.1.11 | UP | **absent** (xadc only) |
| 192.168.1.12 | UP | **AD9361 present** |
| 192.168.1.13 | **DOWN** | unknown — board is off/unreachable |

Still **one radio**, as in every prior wave. Firmware was already proven
byte-identical across .11/.12 (all four QSPI partitions + SD + 54-var env + live
DT), so there is nothing to flash and no software step left: the failure is
physical, and the state flips between power events. `.13` has additionally gone
off the network since the last wave.

This needs hands: a **cold** power cycle of `.11` on **dedicated power** (not the
shared USB hub), and for an actual link, a cabled **SMA + 30-40 dB attenuator** —
over-the-air is illegal here per project law.

## Verification

`device -> node .11 -> node .12 -> device`, Ethernet standing in for the radio
(the bridge needs a transport, not RF), byte-comparing what returns:

```
RECOVERED 35B NAL                                     byte-identical
RECOVERED 605B NAL                                    byte-identical
RECOVERED 2999B NAL                        (43 frags) byte-identical
RECOVERED 8000B NAL                       (115 frags) byte-identical
RECOVERED 9000B NAL                       (129 frags) byte-identical
RECOVERED 1500B sealed, first byte 0x08               byte-identical  <-- new
RECOVERED 900B ending in 0x00                         byte-identical  <-- new
RESULT: 7/7 payloads survived device->node->node->device
```

The last two are the cases the old bridge broke **by construction**: the nonce
collision (A), and H.264's constant trailing zeros against a reassembler that
sized payloads by trimming them.

`cargo test --test video_bridge_wire`: 10/10, including a new guard that the
three ports stay distinct — if they ever collide, the demux ambiguity comes
straight back.

Commits: `2fec5d4`, `b9fe8b2`, `f6f38a0` (repo law updated with both structural
lessons).

## Honest status of the whole path

What is proven: the phone/Mac media stack (tagged `phone-v0.13-audio-works`), and
now the node-to-node datagram path end to end, with real fragmentation, relay and
reassembly of I-frame-sized payloads.

What is not: **the radio link has never carried a single byte**, because two
working AD9361s have never existed at the same moment. Everything above proves
the software around a link that does not yet exist. That is genuine progress —
when a second radio comes up, only the transport underneath changes — but it is
not a field video call, and should not be described as one.

## Three options for the next wave

### 1. Point the real app at the bridge (software, unblocked)
Everything now argues this is close: the bridge is a proven transparent pipe, and
the app's own crypto and fragmentation ride over it untouched. Point the Mac and
the iPhone at `.11`/`.12` instead of at each other and see a real call cross two
nodes. Expect one concrete obstacle: the app fragments at 1200B and the bridge
re-fragments each piece into 18 x 70B, so a single lost VSTREAM fragment kills a
whole app fragment **and then** the whole NAL — double all-or-nothing. The app's
XOR-FEC exists for exactly this and is currently gated off.

### 2. Measure what the node can actually carry (software, unblocked)
`FRAG_RATE_PER_SEC = 800` is a guess. Before tuning a rate to a radio nobody has
measured, measure the node: ingress ceiling, frag throughput, where loss actually
starts. Cheap, and it turns two guesses into numbers.

> **Done in v0.16.** The node sustains 800 datagrams/s (8000 fragments/s,
> ~4.8 Mbps) with zero loss — about 10x the rate limiter's own ceiling. The node
> is not the bottleneck and never was.

### 3. The radio (blocked on you)
Cold power cycle `.11` on dedicated power; bring `.13` back on the network. If a
second AD9361 comes up, the cabled SMA + attenuator link is the last missing
layer — and per this wave's evidence, the software above it is ready for it.

**Recommendation: 1, then 2.** Option 1 is the first time the actual product
would cross the actual mesh, and it is not blocked on anything. Option 3 stays
first in line the moment a second radio exists — but that is hands, not code.
