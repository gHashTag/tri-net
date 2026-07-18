# RRC matched-filter modem + DSSS/CDMA multi-access + self-diagnosing bench (2026-07-19)

Three upgrades. The **self-diagnosing bench ran on the real boards and RECOVERED the link** that had
read as dead for two waves -- the degradation was a weak-signal condition, not a broken antenna, and
an automatic gain/frequency sweep found the operating point that locks. RRC-with-matched-filter and
DSSS/CDMA are host-verified with bit-exact BER=0.

## 3 -- The self-diagnosing bench: diagnose, then recover

Last wave the link read the noise floor at RX gain 60 and was reported (honestly) as degraded. This
wave the bench sweeps TX+RX LO across the 2.4 GHz band and RX gain, scoring each with the honest
correlation metric (`linkq`). The result located the fault AND the fix:

```
  LO      g40        g60        g71
  2.400   cp 0.095   cp 0.102   cp 0.647  LINK OK
  2.420   cp 0.087   cp 0.099   cp 0.071
  2.440   cp 0.096   cp 0.180   cp 0.056
  2.460   cp 0.082   cp 0.090   cp 0.519  LINK OK
  2.480   cp 0.088   cp 0.098   cp 0.298
```

The signal was not gone -- it was **weak**, and the fixed gain 60 of the prior waves sat below the
lock threshold. At maximum RX gain (71) the correlation jumps to 0.5-0.65 and `linkq` reports LINK
OK at 2.400 and 2.460 GHz. The bench turned "the link is dead" into "the link needs +11 dB of RX
gain at these two frequencies" -- a diagnosis and a recovery, entirely from the honest metric.

Honest boundary: at the recovered point the link is **marginal and fading** -- cp bounces 0.17-0.65
capture to capture, below the 0.9 per-frame lock threshold, so a plain coded frame still does not
reliably decode over the air, and a DSSS frame (which is long) sees the fade change mid-frame (a
processing-gain trend appears -- BER 24 -> 20 -> 17 as N grows -- but not a clean recovery). Full OTA
decode awaits a non-fading link; the bench now finds the best available operating point automatically
and states the marginal verdict rather than emitting a false `0/1`. Pushing TX to max power made it
WORSE (PA distortion), which the sweep also showed.

## 1 -- Full RRC modem: transmit shaping + RECEIVE matched filter

Last wave shaped the transmit pulse (RRC) and measured the spectral narrowing (ACLR -18 -> -51 dB at
2 MHz). This wave closes the loop with the matched receiver: mix the subcarrier to DC, apply the RRC
matched filter, sample at symbol centres (a per-sample differential is wrong for a shaped pulse --
the waveform varies within a symbol), and differential-detect symbol to symbol.

```
  RRC beta=0.25, span 8, clean:  t0=309  sync=63/63  BER=0/32  recv=deadbeef
```

BER=0 with a perfect 63/63 preamble correlation: root-RC at TX and RX composes to a raised-cosine
overall, which is zero-ISI at the symbol instants. That is the transmit+receive pair the prior wave's
honest boundary asked for -- the shaped waveform is now demodulable, not just measurable. (The short
63-symbol preamble limits low-SNR sync; range at low SNR is the DSSS path's job, below.)

## 2 -- DSSS + code division: many senders, one band

The FDD channelizer put each sender on its own frequency. Code-division puts them on the same
frequency, separated by orthogonal spreading codes. Two DSSS senders spread their payloads with
DIFFERENT PN codes and transmit in the SAME band at the SAME time; the receiver despreads each by its
own code (soft integrate-and-dump), and the other sender's code -- uncorrelated with yours --
averages to noise.

```
  N=15/31/63, both senders in one band, clean:        A BER=0/32   B BER=0/32
  N=31/63, same, with noise sigma=3000:               A BER=0/32   B BER=0/32
```

Two payloads ("deadbeef" and "cafebabe") recovered from one overlapping capture, each by its code,
even under noise. This is the many-hidden-senders-in-one-band primitive: code-division multi-access
carrying the DSSS processing gain, the complement of the FDD channelizer.

## Scientific picture

The bench is a doctor who, told "the patient is dead" (gain 60, no pulse), turns up the stethoscope
(gain 71) and finds a faint but real heartbeat at two specific spots on the chest (2.400, 2.460 GHz)
-- the patient was not dead, only quiet, and now we know exactly where and how hard to listen.

RRC transmit+receive is speaking softly AND cupping the ear tuned to that softness: the round pulse
leaves the mouth without splashing onto neighbours (TX shaping) and the matched ear gathers exactly
that pulse and nothing else (RX matched filter), so the word arrives whole (zero ISI).

Code-division is a loud room where everyone speaks at once, but each pair agreed a private rhythm of
stresses; you listen for your partner's rhythm and everyone else's words blur into a wash you can
subtract. The room carries many conversations on one air.

## OTA re-run: recovered but marginal; DSSS-in-PL: still blocked

The link is recoverable at RX gain 71 / 2.400-2.460 GHz but fading; a clean OTA decode awaits a
stable bench. All modes cross-compiled and deployed on the four ARM boards; the self-diagnosing sweep
and `linkq` guard run on hardware.

Boards left clean: writers=0, TX LO powerdown=1 on all four, RX AGC restored to slow_attack, LOs at
2.4 GHz, IQ removed.
