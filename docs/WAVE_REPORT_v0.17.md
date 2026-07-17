# Wave v0.17 — FEC on the fragment layer, and the burst bug it exposed

All three tracks were asked for. Option 2 (make loss survivable) is done and
proven on hardware. Option 1 is still blocked on the iPhone. Option 3 is
unchanged. The most valuable thing this wave produced was not the feature — it
was discovering that the previous wave's "7/7 proven" was luck sitting on a
cliff edge.

## What was built

One XOR parity per group of 16 fragments (6% overhead), repairing any single
loss per group. Reassembly is all-or-nothing and an I-frame is 129 fragments, so
before this **one lost 70-byte packet destroyed a whole keyframe**.

The wire format and the group arithmetic live in `specs/video_bridge.t27` — the
source of truth — and the daemon does only byte plumbing:

```
parity: [9][seq_lo][seq_hi][group_idx][frag_count][last_len][xor:70]
```

`last_len` rides in the **parity**, not only in the final fragment: a receiver
that lost exactly the last fragment could otherwise recover its bytes but not
know how many of them were real.

## The bug the feature exposed

Adding parity took the probe from **7/7 to 5/7** — the two biggest NALs stopped
arriving. The parity was not at fault; it was the last straw:

```
single 9000B NAL, 138 packets sent as one burst
.12 kernel: +94 datagrams in, +44 rcvbuf drops
```

The rate limiter enforced a per-second **budget** and never paced. A whole NAL
left in under a millisecond: average rate correct, **instantaneous rate ~100x the
target**. The peer's socket buffer holds ~140 small packets. At 129 it fit; at
138 it did not.

**A budget is not a rate.** And this is not an Ethernet artefact — a 480 kbps
radio queue would drop in exactly the same way, worse. The v0.15 report claimed
the 9000B I-frame was "proven" at 7/7; it was passing with 2% margin on a cliff
nobody had looked at.

Fragments are now spaced one token apart. A 9000B I-frame takes **172ms**, which
is simply what 480 kbps costs (9000 x 8 / 480k = 150ms of physics). That latency
is the honest price of the link, not a regression.

## Two more defects, both in the reporting

- **Duplicate delivery.** Parity trails its data on the wire, so removing the
  reassembly entry at delivery let a late parity re-create it, "repair" the
  payload out of the parity alone (for a one-fragment group the parity *is* the
  fragment) and deliver it a second time. Entries now outlive delivery until the
  GC sweeps them.
- **A lying counter.** `repair_groups` runs per packet and each parity fixes its
  own group, so the final call returns 1 regardless — a NAL rescued from **nine**
  losses logged `[FEC repaired 1]`. This feature exists to make loss survivable;
  a counter that under-reports it 9x hides the exact thing it was added to show.
  Now: `[FEC repaired 9 of 9 groups]`.

## Verification

The board's `tc` is a busybox stub with **no netem**, so the link cannot be
impaired from outside. Instead the Mac **plays the sending node** — speaking the
real VSTREAM wire format straight into `.12`'s mesh port and withholding chosen
fragments. That is stricter than netem: the loss pattern is exact, so each claim
is tested alone rather than hoping randomness covers it.

```
payload: 9000B = 129 fragments, 9 parity groups     target: real daemon on .12

[PASS] no loss (control)
[PASS] drop fragment 0 (first of group 0)
[PASS] drop fragment 7 (middle of group 0)
[PASS] drop fragment 128 (LAST -- length comes from parity)
[PASS] drop 1 per group, 9 groups, 9 losses  -> [FEC repaired 9 of 9 groups]
[PASS] drop 2 in one group (unrepairable)    -> delivered NOTHING, not garbage
6/6
```

Plus **7/7** end-to-end `device -> .11 -> .12 -> device`, and **15/15** wire
tests — including a round trip that rebuilds every one of a 9000B NAL's 129
fragments from parity, and a guard on the `u8` shift overflow `fec_group_first`
would hit at group 16 (unreachable while `frag_count` is `u8`: 255 fragments need
16 groups, highest index 15).

A first attempt at an A/B with `tc netem` **measured nothing** — the qdisc never
applied and both arms ran on a clean link at 100%. The script printed an empty
`netem:` line and I nearly believed the result. Third time this session that an
unverified instrument produced a confident non-answer.

Commit: `ada5c4c`.

## What I broke and had to restore

`cargo build` rewrites 68 tracked files under `gen/`, so the tree is always
dirty. I "cleaned" it with `git checkout -- gen/` — and **broke the build**: the
committed contents of `gen/` do not compile. The local t27c has drifted from
whatever produced them (it now emits `as u32` casts). Recovery was `touch
specs/*.t27 && cargo build`.

This is a structural trap, now documented in `CLAUDE.md`:
- the committed `gen/` does not compile;
- `build.rs` silently fixes it locally from the sibling `t27` repo, and silently
  skips if that repo is absent;
- the `no-gen-edits` hook forbids committing the working versions;
- 16 of 84 generated modules — including `video_bridge.rs`, which the whole
  bridge depends on — are **untracked**, with no ignore rule.

This repo builds only on a machine with `t27` beside it. That is worth fixing,
but it cannot be fixed from inside the hook's rules.

## C — radio, unchanged

| board | ping | radio |
|---|---|---|
| .11 | UP | **absent** (xadc only) |
| .12 | UP | **AD9361 present** |
| .13 | **DOWN** | unreachable |

One radio, as in every wave. Hands, not code.

## Honest status

The mesh's software now survives loss, paces to its promised rate, demuxes an
encrypted channel correctly, and never guesses a length. All of it is still
**software around a link that has never carried a byte**. What this wave adds is
that the layer a radio will actually stress — per-fragment loss — is now built
and tested, rather than waiting for the radio to discover it the hard way.

## Three options for the next wave

### 1. The real app across the mesh (two minutes of your hands)
Unchanged and still the biggest single step: type `192.168.1.11` into the Mac's
Remote IP field and `192.168.1.12` into the iPhone's, press Start on both. Both
nodes are running and waiting. No app change is needed.

### 2. Measure the FEC's real cost/benefit under sustained load (unblocked)
The 6% overhead and the 172ms pacing latency are now real, and both are
guesses about a radio that does not exist. Under sustained video (not one NAL at
a time) the pacing may serialise behind a backlog, and bursty loss — the kind a
socket buffer or a radio actually produces — defeats a group parity that only
repairs one-in-16. Measuring that would tell us whether the group size is right,
or whether interleaving is needed.

### 3. The radio (blocked on you, unchanged)
Cold cycle `.11` on dedicated power; bring `.13` back.

**Recommendation: 2.** Its premise is directly testable with the harness this
wave built, and its answer changes the design (group size, interleaving). Option
1 remains a two-minute unlock whenever you are at the machine.
