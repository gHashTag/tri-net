# Fade physics + a clean OTA byte caught + whole-stack report (2026-07-19)

Two hardware results and a consolidation. The fade profile MEASURED the channel's physics on the
boards, that measurement said a clean byte was catchable, and selection combining then CAUGHT one:
`recv=deadbeef BER=0/32` over the air. The multi-wave OTA gap is closed.

## 2 -- Fade physics on hardware: slow fade, long good windows

A cyclic TX repeats one frame; each received copy's preamble correlation cp[k] samples the channel
every frame period (125 us). `fadeprofile` scores every copy in a long capture and reports the
statistics. Three back-to-back captures on the real link:

```
  run1:  cp mean 0.180  min 0.025  max 0.279   decodable(cp>=0.85) 0/129 (0%)    lag1 0.88 slow fade
  run2:  cp mean 0.982  min 0.102  max 1.000   decodable          126/129 (98%)  lag1 0.58 slow fade
  run3:  cp mean 0.707  min 0.028  max 1.000   decodable           89/130 (68%)  lag1 0.96 slow fade
```

Two physics facts fall out, both actionable:

- **The fade is SLOW.** The lag-1 autocorrelation of cp[k] is 0.58-0.96, i.e. the channel barely
  changes from one 125 us frame to the next -- coherence time is many frames. That is an
  antenna/thermal/mechanical fade, not fast multipath. Consequence: a good moment is not a single
  lucky frame, it is a long run of decodable frames.
- **Good windows exist and are usable.** run2 shows 98% of frames (126/129) at cp>=0.85 -- the link
  was, for that ~16 ms window, essentially clean. The trouble was never that the link is dead; it is
  that it swings (run mean 0.18 -> 0.98 -> 0.71 over seconds) and a blind capture often lands in a
  trough.

The measurement directly prescribes the fix: because the fade is slow, capture a window that spans
many frames and pick the best copy -- selection combining will find a cp~1.0 frame whenever the
window is anywhere near a good one.

## 1 -- A clean OTA byte, caught

Acting on the physics, a loop of selection-combining decodes (`otarxbest`, which scores every cyclic
copy and decodes the best) over the recovered link (2.400 GHz, RX gain 71):

```
  try1:  copies=130  best_cp=1.000  BER=0/32  recv=deadbeef  exp=deadbeef   === CLEAN OTA BYTE CAUGHT ===
```

First capture, best copy at cp=1.000, zero bit errors, the exact payload. A clean byte over the air
on the link that read as noise for several waves -- recovered by the auto-gain sweep (gain 71),
characterized by the fade profile (slow fade, good windows), and caught by selection combining (best
of 130 copies). Every piece of the honest-instrument chain earned its place: the correlation guard
that told the truth about the link, the sweep that found the gain, the profile that read the fade,
and the combiner that caught the wave.

## 3 -- Whole-stack report

A single consolidated report of the DePIN radio stack across all waves -- security (keyed MAC, epoch
anti-replay, sliding window), PHY (wide-band FDD, RRC shaping, DSSS/CDMA), robustness (selection
combining, closed-loop adaptation, fade physics), coding (RLNC, RLNC-over-CDMA), and the capacity
budget -- with each claim tagged PROVEN-OTA / host bit-exact / projection. Published as a living
artifact alongside the pitch and integration brief.

## Scientific picture

The fade profile is a tide table read from the water itself: watch the level every few seconds and
you learn the rhythm -- slow swells, not choppy chop -- and you learn that high water does come, and
lasts. The clean byte is then just launching the boat at high tide instead of dragging it across the
mud: the honest instruments told us when the tide was in, and we went.

## Boards clean; DSSS-in-PL still blocked

All modes cross-compiled and deployed on the four ARM boards; fadeprofile, otarxbest, otatrig, linkq
and the adaptation loop run on hardware. The RF link is fading but recoverable and now
characterized; a clean single-source byte is caught, multi-source (RLNC-over-CDMA) OTA is the next
good-window target.

Boards left clean: writers=0, TX LO powerdown=1 on all four, RX AGC restored, LOs at 2.4 GHz, IQ
removed.
