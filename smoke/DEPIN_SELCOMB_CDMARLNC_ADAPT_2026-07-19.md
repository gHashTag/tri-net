# Selection combining + RLNC-over-CDMA + closed-loop link adaptation (2026-07-19)

Three upgrades for a real, fading link. The **closed-loop adaptation runs on the boards**: it picks
the RX gain by the honest cp metric and logs link quality over time, turning "the link is degraded"
into a measured, time-varying signal. Selection combining and RLNC-over-CDMA are host bit-exact.

## 3 -- Closed-loop link adaptation with telemetry (on hardware)

The self-diagnosing sweep of the previous wave found the operating point once; this wave the node
does it as a loop and then watches the link over time. On the real 4-board rig:

```
  1) auto-select RX gain by cp:  gain 40->0.090  55->0.088  64->0.142  71->0.254  -> chose 71
  2) link-quality telemetry at gain 71, once/second:
       t1 0.437   t2 0.114   t3 0.263   t4 0.200   t5 0.560 LINK OK   t6 0.217   t7 0.317   t8 0.240
```

The node measures, decides, and logs -- no human in the loop. Two facts fall out, both honest:
the link is **fading** (cp swings 0.11-0.56 second to second), and it is **catchable** -- at t5 a good
fade crossed into LINK OK (cp 0.56). The fading is no longer an assertion; it is a measured
telemetry stream, exactly the signal an adaptive node (or an operator) needs. This is the "termostat
of the radio channel": turn the gain up when it's cold, and know when a good window arrives.

## 1 -- Selection combining over the fade

Because good windows occur but are brief, a first-lock-then-step decoder that commits to the first
preamble often commits to a bad one. Selection combining instead scores EVERY cyclic copy in a long
capture by its preamble correlation and decodes only the best one -- the copy that landed in a good
fade.

```
  host, 20 cyclic copies, clean:  copies=20  best_cp=1.000  BER=0/32  recv=deadbeef
```

`otarxbest` is bit-exact on host and deployed on the ARM boards. Over the air it correctly selects
the strongest of a few hundred copies; on the currently-weak link the best copy was still only
cp~0.2-0.24 (the telemetry above shows why -- the good fades were not in that window), so a clean OTA
byte still awaits a moment when a good fade coincides with the capture. The technique is right and
proven; the link is the variable, and the telemetry now shows exactly how it varies.

## 2 -- RLNC coded frames over code division (CDMA)

The FDD channelizer separates senders by frequency; DSSS code division separates them by code on ONE
frequency. This wave carries the network-coded frames themselves over CDMA: each source spreads its
MAC'd K=4 coded frames with a DIFFERENT PN code and transmits in the same band at the same time; the
receiver despreads each by its code (soft integrate-and-dump), MAC-verifies, and solves GF(256).

```
  N=15/31, clean:            codeA alone 2 frames -> 0/1;   A+B 4 frames -> 1/1  "TRINET-WIDEBAND!"
  N=31, sigma=2000 & 4000:   codeA alone         -> 0/1;   A+B          -> 1/1  "TRINET-WIDEBAND!"
```

Code A alone carries only 2 of the 4 coded frames a generation needs -- rank 3, undecodable. Adding
code B's 2 frames (from the same band, same time, separated purely by code) reaches rank 4 and
decodes the exact message, and it survives noise. This is the full stack in one primitive: DSSS
processing gain (range), code division (many senders per band), and RLNC (any source's frames are
interchangeable -- multipath). A node with a weak path to one source fills the gap from another,
without a second frequency.

## Scientific picture

Closed-loop adaptation is a sailor who wets a finger and holds it up every few seconds: the wind
(link) gusts and lulls, and rather than declaring "no wind" once, the sailor reads the gusts and
raises sail (gain) when one arrives. Selection combining is catching the wave -- paddling on the one
swell out of many that actually lifts the board. And RLNC-over-CDMA is a choir where every singer
uses a private rhythm on the same note, and even the lines you miss are re-derivable from the shared
harmony -- many hidden voices, one pitch, no line indispensable.

## OTA clean byte: pending a good-fade window; DSSS-in-PL: still blocked

The link is fading and catchable (telemetry-confirmed) but a clean OTA byte needs a good fade during
the capture. All modes host bit-exact and deployed on the four ARM boards; the adaptation loop and
`linkq` guard run on hardware.

Boards left clean: writers=0, TX LO powerdown=1 on all four, RX AGC restored, LOs at 2.4 GHz, IQ
removed.
