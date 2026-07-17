# Wave v0.18 — the parity was guarding against loss this system cannot produce

Last wave shipped FEC and recommended measuring whether the group size was right.
It was not. One measurement settled it, and the fix was an index mapping.

## The measurement

Same 9000B keyframe, same daemon, same number of losses. **Only the shape
differs.** Contiguous groups of 16:

| losses | shape | outcome |
|---:|---|---|
| 2 | scattered (1 per group) | DELIVERED |
| 2 | **consecutive** | **LOST** |
| 4 | scattered | DELIVERED |
| 4 | **consecutive** | **LOST** |
| 8 | scattered | DELIVERED |
| 8 | **consecutive** | **LOST** |

**Two adjacent losses killed a keyframe.** The parity grouped 16 *contiguous*
fragments, so it repaired one *isolated* loss per group — and neither loss source
this system has is isolated:

- a full socket buffer drops **consecutive** arrivals (measured last wave: a
  138-packet burst cost 44 consecutive at the peer);
- a fading radio drops **consecutive** symbols.

The layout was protecting against the one shape reality does not produce. The 6%
overhead was being spent on nothing.

## The fix

Groups are now **interleaved**: group `g` holds fragments `g, g+stride,
g+2*stride, ...` where `stride` = the group count. A burst of up to `stride`
consecutive losses lands one-per-group, every one repairable.

Same overhead, same packet count, same parity math — **only the index mapping
changes**. `fec_group_of` now needs `frag_count` (the stride depends on it),
`fec_group_first` is the group index itself, and `fec_group_len` counts indices
congruent mod stride. The `u8` shift overflow that `group_idx * 16` used to risk
disappears with the multiplication.

Re-run on the same daemon:

| losses | shape | before | after |
|---:|---|---|---|
| 2 | consecutive | LOST | **DELIVERED** |
| 8 | consecutive | LOST | **DELIVERED** |
| 9 | consecutive | LOST | **DELIVERED** — `[FEC repaired 9 of 9 groups]` |

## What it costs — stated plainly

**Interleaving does not make the parity stronger. It moves the blind spot.**

| losses | shape | interleaved |
|---:|---|---|
| 2 | consecutive | DELIVERED |
| 2 | spaced exactly 9 apart | **LOST** |
| 2 | random | DELIVERED |
| 8 | consecutive | DELIVERED |
| 8 | spaced exactly 9 apart | **LOST** |
| 8 | random | **LOST** |

"Spaced exactly stride apart" now dies where it used to survive. That is a good
trade **only** because the system produces consecutive loss and nothing here
produces a periodic every-9th-packet loss — but it is a trade, not a free win.

Both layouts are identical under *random* loss, and both lose above ~stride/3
losses: 8 random losses across 9 groups collide by the birthday argument
(P(all distinct) ~= 0.8%), so that NAL is correctly LOST. One repair per group is
the ceiling of an XOR parity; beating it needs a real erasure code, not a
different layout.

## Verification

- **6/6** exact-loss cases against the deployed daemon, including the last
  fragment (length arrives via the parity) and a true negative: two losses in one
  group deliver **nothing**, not garbage.
- **7/7** end-to-end `device -> .11 -> .12 -> device`.
- **15/15** wire tests, including a new one that walks every NAL size 2..255 and
  asserts a stride-length burst at **every** offset hits distinct groups.

The board's `tc` is a busybox stub with no netem, so the Mac plays the sending
node — speaking the real wire format into `.12`'s mesh port and withholding an
exact pattern. Stricter than netem: each claim is tested alone.

Commit: `69edfe2`.

## Two ways I nearly reported a false result

Both worth recording; neither was caught by the code.

1. **The probes compute parity themselves**, so after the layout changed they
   still spoke the *old* one. Re-running unchanged would have "measured" a
   protocol mismatch and called it a regression.
2. **The labels inverted their meaning.** The probe's "scattered (1 per group)"
   case dropped fragments 0, 9, 18... — which under stride 9 are **all in group
   0**. The table printed `scattered -> LOST` and `burst -> DELIVERED`, which
   reads like nonsense until you notice the label now describes the opposite of
   what it does. One test case (`fec_loss.py`) genuinely FAILED for this reason
   and the code was innocent. A harness that speaks the wire format must be
   updated with it, and a test that lies about what it tested is worse than no
   test.

## C — radio, unchanged

`.11` no radio, `.12` has one, `.13` unreachable. One radio, as in every wave.

## Honest status

The mesh's software now survives the loss shape a radio will actually deliver.
That is a real step: the layer a link stresses hardest is built, measured, and
its limits are known rather than assumed. It is still **software around a link
that has never carried a byte**.

## Three options for the next wave

### 1. The real app across the mesh (two minutes of your hands)
Unchanged and still the biggest single step. Type `192.168.1.11` into the Mac's
Remote IP field, `192.168.1.12` into the iPhone's, press Start on both. Both
nodes are running and waiting; no app change is needed.

### 2. Sustained load — the question v0.17 asked and this wave did not answer
This wave measured loss *shape* and stopped there. The other half is still open:
under continuous video (~30 NALs/s, not one at a time) the 172ms pacing of an
I-frame serialises behind the P-frames queued after it, and the source wants
~900 frags/s against an 800 frags/s ceiling. Nobody has measured what latency
and drop rate that actually produces. It needs no radio and no phone.

### 3. The radio (blocked on you, unchanged)
Cold cycle `.11` on dedicated power; bring `.13` back.

**Recommendation: 2.** It is the last unmeasured assumption in the bridge, it is
unblocked, and the harness for it already exists. Option 1 remains a two-minute
unlock whenever you are at the machine.
