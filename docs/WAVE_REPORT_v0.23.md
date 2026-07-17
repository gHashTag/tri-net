# Wave v0.23 — the dead zone was a red herring; the step law was the lever

v0.22 blamed the wasted ~25% of link on the hysteresis band. This wave measured
the real cause, and in doing so caught a measurement error in my own earlier
report.

## First, I had been measuring the wrong law

v0.21 reported the shipping app converges cleanly: "524 frags/s, 0% swing." That
was measured with the harness's own step law (x0.8 down / x1.1 up). **The real
app uses x0.7 / x1.2.** Run with the app's actual law, the shipping product does
not converge cleanly — it oscillates 36%:

```
dead zone 75/85, x1.2 up, x0.7 down -> 493 frags/s (70%), swing 36%
```

That is the configuration on the phone in your hand. The lesson is blunt: measure
the law the product runs, not a stand-in that happens to be nearby.

## The sweep

60s each, synthetic encoder from 2000 frags/s into a 700 frags/s budget, obeying
the node's advice exactly as the app does:

| law | settled | swing | steady drops |
|---|---:|---:|---:|
| dead zone 75/85, x1.2 up, x0.7 down (**shipping**) | 493 (70%) | 36% | — |
| no zone, +25 up, x0.7 down | 481 (69%) | 21% | — |
| no zone, +25 up, **x0.9** down | 602 (86%) | 28% | — |
| no zone, **+15** up, **x0.9** down | 543 (78%) | 14% | **0** |

Two things fall out, and neither is the band:

- **The gentle multiplicative decrease recovers the wasted headroom.** x0.7 cuts
  30% per back-off, which additive climb then spends dozens of steps clawing
  back, so the loop lives far below the ceiling. x0.9 cuts 10%, and the average
  rises from ~70% to ~86% of the link.
- **The additive increase stops the oscillation.** Removing the dead zone while
  keeping x1.2/x0.7 still swings 35% — the zone never mattered. A constant +N
  step cannot overshoot the way a x1.2 multiply does near the ceiling.

**+15 up / x0.9 down** is chosen: 78% of the link at 14% swing with **zero
steady-state loss**, confirmed on the node — the last 200 admission decisions had
zero drops; all 378 drops in the run were the initial descent from 2000.

## What shipped

- **Spec**: no dead zone. `CLIMB_BELOW == BACK_OFF == 85`, so advice is CLIMB
  whenever there is any headroom at all. The invariant is flipped to assert the
  two are **equal** — if they ever diverge again a HOLD region reopens and the
  loop freezes in it, and the invariant now fails the build instead of letting it
  ship.
- **Both encoders**: AIMD. +10 kbps additive up, x0.9 multiplicative down (the
  app works in bitrate; 15 frags/s ~= 10 kbps at this link). Both were x1.2/x0.7.

15/15 wire tests. Both apps rebuilt and installed. Nodes at the radio budget.

## Not yet verified end to end

Everything above is on the synthetic encoder, which this wave showed is exactly
the trap to avoid trusting. The real check — does the product now sit near 80%
instead of swinging 36%? — needs the call restarted: Mac Start with
`192.168.1.11`, iPhone with `192.168.1.12`.

## C — radio, unchanged

`.11` no radio, `.12` has one, `.13` unreachable. Hands, not code.

## Honest status

The backpressure loop now seeks the link's capacity instead of freezing below it,
and does so without steady-state loss — the last real gap in the bridge's control
behaviour. All of it still runs over Ethernet at the radio's *budget*, not over
the radio. The AD9361 link has still never carried a byte.

## Three options for the next wave

### 1. Confirm AIMD on the real product (a minute, needs the call)
The one measurement this wave did not take. Restart the call through the mesh and
watch the Mac's bitrate: it should climb in small steps and hold near 80% of the
budget, not swing. If it matches the sweep, the control story is closed and
measured on the product end to end.

### 2. Make the ceiling adapt to the link, not a constant (unblocked)
`FRAG_RATE_PER_SEC` is still a fixed 800. A real radio's capacity varies with
range and fading. The node could estimate its own deliverable rate from the
egress it actually achieves and feed *that* into the budget, so the whole loop
tracks a moving link instead of a typed-in number. This is the last "guess"
left in the bridge.

### 3. The radio (blocked on you, unchanged)
Cold cycle `.11` on dedicated power; bring `.13` back. Everything above is built
and measured against the budget a radio would impose — it is waiting only for the
link.

**Recommendation: 1.** It is a minute and it closes the loop the last five waves
built, on the product rather than a model. Then 2 is the final guess to retire.

## Addendum: verified on the product

The call was restarted with the AIMD build. The app's log caught the descent —
552 -> 497 -> 447 -> 403 -> 362 -> 326 kbps, exact x0.9 steps — and the node
confirms the equilibrium: **zero drops in the last 300 admission decisions**,
utilisation oscillating 85-98% with `drops=0%` in every report. The AIMD sawtooth,
on the product, at the radio budget. The percent signs in the log are also
correct now.

One discovery from the live traffic mix: every audio packet costs TWO fragments
(`TX 58B -> 1 frag + 1 parity` — a parity over one fragment IS a copy), and audio
still rides the video port at 50 pkts/s = 100 frags/s, a seventh of the whole
budget, half of it duplicates. The express port (7002) is built and measured but
the app does not use it yet. Moving audio there returns ~14% of the video budget
and takes audio out of video's queue — one destination change per platform.
