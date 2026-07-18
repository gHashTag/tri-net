# Sliding replay window + 3-source channelizer + coherent processing gain (2026-07-19)

Three link upgrades, all verified **bit-exactly on host**. The over-the-air rig that carried the
previous wave's features (committed the same day) had **degraded** by the time these ran -- the
received power fell to the noise floor with the transmitter at full power -- so OTA re-verification
is pending a stable bench. The engineering is proven; only the last radio confirmation is deferred,
and it is deferred honestly rather than reported on a link that reads as noise.

## 1 -- Full anti-replay: an RFC 6479 sliding window

Last wave's `min_epoch` was a monotone threshold: it rejects anything below a high-water mark, but
it also rejects legitimately *reordered* fresh frames, and it cannot reject a replay that carries a
seq at or above the mark. This wave replaces it with a proper sliding window (W=64): state is a
`(high, bitmap)` pair, where bit `i` means "seq `high-i` already seen". A frame is **accepted** if
its seq advances the window or falls in-window with its bit clear (reorder-tolerant), and
**dropped** if its bit is already set (duplicate = replay) or it is older than the window. The seq
lives under the MAC, so it cannot be forged.

Host, one generation of seq 100..105:

```
  (a) fresh, empty window (high=-1)            -> accepted=6  decode 1/1  "TRINET-WIDEBAND!"
                                                  WINSTATE high=105 bitmap=0x3F
  (b) REORDER: window seeded high=105 bitmap=0 -> accepted=6  decode 1/1   (all <= high, bits clear)
  (c) REPLAY:  window seeded high=105 bitmap=0x3F -> accepted=0 dup=6 decode 0/1
```

Cases (b) and (c) share the same `high=105` and differ only in the bitmap, yet one accepts all six
and the other rejects all six. That is the whole point: the window distinguishes "already seen"
from "merely old" -- a monotone counter cannot, and would either reject the reordered fresh frames
or admit the replay.

## 2 -- Three concurrent sources from one capture (complex band-pass channelizer)

Last wave harvested two FDD bands from one capture with a boxcar filter. A boxcar is a *symmetric*
low-pass, and the DBPSK subcarrier is one-sided (+768 kHz), so a lower-adjacent channel's subcarrier
mirrors onto -732 kHz -- which a symmetric filter cannot separate from the wanted +768 kHz. This
wave adds a **complex band-pass** (heterodyne the subcarrier to DC, Kaiser low-pass, heterodyne
back) that rejects that negative-frequency image, and lifts the harvest to **three** simultaneous
senders.

Host, three sources (src 0/1/2, one K=4 generation, ncoded=4 each) placed at -2/0/+2 MHz, summed
into one capture:

```
  decode all 3 bands (mix -2/0/+2 MHz, Kaiser band-pass) -> 1/1  "TRINET-WIDEBAND!"
  decode one band alone                                  -> 0/1  (4 of 12 coded frames)
```

**Honest boundary (a real finding).** The DBPSK main lobe is +-768 kHz wide (symbol rate = subcarrier
frequency), so two channels closer than ~2 MHz physically overlap -- no filter can separate them;
that needs a narrower transmit pulse (RRC shaping), which is a transmitter change and becomes a
next-Wave option. And at a *robust* operating point (ncoded=4) the coding redundancy absorbs the
boxcar's mirror leak, so the band-pass's advantage over the boxcar only shows in the marginal regime
(a surrounded middle band at ncoded=2, where both in fact fail). The provable, non-inflated claim is:
**three simultaneous senders, one antenna, one capture, decoded 1/1.**

## 3 -- Coherent averaging: a software preview of DSSS processing gain

A DSSS despreader buys processing gain by integrating a repeated code. As a preview we coherently
average M cyclic copies of a frame -- summing the raw IQ *before* the differential detector, so the
signal adds in amplitude while the noise adds in power -- then demodulate. The gain is ~10*log10(M).

Host, signal amplitude ~2200, additive complex Gaussian noise sigma=5000 (SNR ~ -7 dB):

```
  M=1   BER=33/64   (a single copy is pure noise)
  M=8   BER=18/64
  M=16  BER= 6/64
  M=32  BER= 1/64   recv=deadbeefcafababe   (~15 dB gain lifts the payload out of the noise)
```

BER falls monotonically with M, tracking the 10*log10(M) law. This is coherent averaging of a
*repeated* signal, not the real spread-spectrum (which spreads a unique payload) -- hence a preview
of the gain, honestly labelled. Full DSSS despreading in the PL stays blocked on Vivado + ADI-HDL.

## Scientific picture

The epoch was a doorman who only checks that your ticket is dated today; a photocopy of today's
ticket still gets you in. The sliding window is a doorman with a **guest list he crosses off**: your
name can be anywhere on today's page (reorder), but once it is crossed off, the copy is turned away.

The boxcar channel filter was a hand cupped to one ear -- it hushes what is far to the side but
cannot tell a voice on your left from its echo on your right. The complex band-pass is a
**directional ear trumpet aimed at one speaker's pitch**: the mirror-image echo of a neighbour no
longer counts, so a third speaker fits between the first two.

Coherent averaging is listening to the same word shouted thirty-two times in a gale and writing down
only what is the same every time: the wind cancels, the word remains.

## OTA status (honest)

The same 4-board rig decoded the previous wave's features over the air earlier today. When these
three modes were run OTA, the received power had fallen to the noise floor (rms ~20, transmitter at
0 dB / full power), and the previous wave's own script -- which had decoded 1/1 hours earlier --
also read 0/1. That is a physical link degradation (antenna/thermal/bench drift), not a code fault:
the decoder honestly reported "no signal", the independent power probe confirmed it. Rather than
report a number produced on a link that reads as noise, OTA re-verification is deferred to a stable
bench. All three modes are bit-exact on host and cross-compiled/deployed on the ARM boards.

## DSSS on a big FPGA: still blocked

Re-scan: only `.1` (router), `.10/.11/.12/.13` (four P201Minis), the host. Needs Vivado + ADI-HDL.

Boards left clean: writers=0, TX LO powerdown=1 on all four, RX AGC restored to slow_attack, LOs
back to 2.4 GHz, IQ files removed.
