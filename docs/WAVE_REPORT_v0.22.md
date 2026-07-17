# Wave v0.22 — iOS hears its node; and the band sweep refuted its own premise

All three tracks. The measurement one is the valuable one, because it proved me
wrong.

## 1. iOS mirror — done and installed

The iPhone 13 Pro is attached, so this stopped being blocked. `BSDTransport` now
listens on `FEEDBACK_PORT` and `StreamViewModel`'s ABR obeys the node's verdict,
falling back to the PLI loop when no report has arrived for 5s — a direct
peer-to-peer call has no node, so silence there is normal, not a fault. **No
thresholds in Swift**: the node decides, the app obeys.

Built, installed on the device. Its node had been advising

```
[link] BACK OFF: util=86% drops=0% rate=700/s -> 192.168.1.103
```

preemptively — at 86% load with **zero** loss — into a listener that did not
exist. That advice now lands.

**Not yet verified end to end**: `devicectl process launch` returned
`RequestDenied`, which is what a locked device gives. Unlock the phone and press
Start with `192.168.1.12`.

## 2. The band sweep — my hypothesis was wrong

v0.21 found the loop parks at 75% of the link and blamed the width of the
hysteresis band (climb below 60%, back off at 85%). This wave made the thresholds
function inputs so they could be **measured instead of argued**, and swept them
on hardware — 45s each, synthetic encoder starting at 2000 frags/s into a 700
frags/s budget:

| band | settled | swing |
|---|---:|---:|
| climb<60, back-off>=85 | 524 (75%) | 0% |
| climb<75, back-off>=85 | **524 (75%)** | 0% |
| climb<82, back-off>=85 | 519 (74%) | **22%** |

**Narrowing the band recovers nothing.** 60 and 75 are identical to the fragment.
82 only starts it oscillating, for no gain.

The trace says why:

```
819 -> 655 -> 524, and at 524 utilisation first reads 80%
```

80% is inside the hold band, so **everything freezes**. The loop does not *seek*
the ceiling — it backs off until it falls into the dead zone and stops. **524 is
merely where the x0.8 steps happened to land.** It is an arbitrary point that
would differ from another starting rate, and it has nothing to do with the link's
capacity.

So the law is stable and lossless, and its equilibrium is an accident. That is
worth knowing plainly: the ~25% of unused link is the **dead zone's** doing, and
fixing it needs a seeking law (additive increase, no dead zone), not a different
band. 75/85 is kept only because it measured identical to 60/85 and reacts
sooner — not because it is optimal.

## 3. Radio — unchanged

| board | ping | radio |
|---|---|---|
| .11 | UP | **absent** (xadc only) |
| .12 | UP | **AD9361 present** |
| .13 | **DOWN** | unreachable |

One radio, as in every wave. Hands, not code.

## The sweep lied first, twice

Both worth recording; both were mine, and neither was the code under test.

1. **Three runs reported STALLED.** The daemon was innocent: zsh does not
   word-split an unquoted parameter, so `set -- $BAND` made `CLIMB_BELOW="60 85"`
   and the remote shell tried to execute `85` as a command — `sh: 85: not found`.
   The daemon never started. The runner now **verifies the process is up before
   believing any number it produces**.
2. Earlier in v0.21, the same harness reported STALLED for 60 straight seconds
   because I had changed the wire format to 6 bytes and rebuilt for the host
   without redeploying to the boards.

Both times a real result was ready to be reported from a rig that was not
running. The only thing that caught either was a crash on a byte that should have
existed.

## Verification

15/15 wire tests. Nodes restored at the radio budget (800 frags/s = 480 kbps),
both apps rebuilt and installed. Commit `672622f`.

## Honest status

The mesh carries a real call, survives the loss shape a radio produces, keeps
audio out of video's queue, and now tells the encoder what the link is doing —
and both apps listen. All of it still runs over **Ethernet**. The radio has never
carried a byte.

## Three options for the next wave

### 1. Prove the loop on the real app (needs the phone unlocked, ~1 minute)
Both apps now hear their node and both nodes sit at the radio budget. Unlock the
iPhone, Start with `192.168.1.12`; on the Mac, `192.168.1.11`. The Mac used to
lose 44% silently at this budget — it should now throttle instead, and say so:
`ABR down — node: util=..% drops=..%`.

### 2. Replace the dead zone with a seeking law (unblocked)
This wave's measurement points straight at it: the loop freezes at an arbitrary
point and leaves ~25% of the link unused. Additive increase (small, constant
steps up while there is room) plus the existing multiplicative decrease would
seek the ceiling instead of freezing below it. The harness to measure it already
exists, and the answer is a number, not an argument.

### 3. The radio (blocked on you, unchanged)
Cold cycle `.11` on dedicated power; bring `.13` back.

**Recommendation: 1, then 2.** Option 1 is a minute and turns the whole
backpressure story from "measured on a synthetic encoder" into "measured on the
product". Option 2 is the real engineering left in the bridge.
