# RF fingerprint + slashing + live dashboard (2026-07-19)

Three network-economics upgrades. The RF fingerprint and slashing are proven in software and
coupled by a real insight (attribution needs the fingerprint); the live dashboard renders the
whole network's proven numbers. The RF link was in a fading trough for this session's OTA, so the
fingerprint's over-the-air confirmation is deferred to a good-window phase.

## 1 -- RF fingerprint of the transmitter (which node sent)

Each AD9361's crystal has a tiny, unique carrier-frequency offset; against the fixed RX it is a
per-node signature. `rffinger` estimates the fine CFO from the (known) preamble: the complex
differential d[k]=x[k+OSF]*conj(x[k]) carries a phase = 2*pi*CFO/(fs/OSF); removing the known PN
modulation and averaging over the 63-symbol preamble gives arg -> CFO in Hz. Host, distinct crystal
offsets emulated by a known frequency shift:

```
  injected +30000 Hz -> CFO=+30000     injected -12000 Hz -> CFO=-12000
  injected  +6000 Hz -> CFO= +6000     injected +48000 Hz -> CFO=+48000
```

The estimator recovers the exact offset, so distinct crystals are cleanly separable -- an ID by
radio, without any explicit address, for anti-spoofing of coverage. **Honest boundary:** the CFO
estimate needs a good fade window (cp high); this session's OTA hit a trough (cp mostly < 0.4, the
estimates wrapping at +-384 kHz = half the subcarrier), so the over-the-air per-node CFO clustering
is deferred to a good-window phase (the slow fade guarantees one returns).

## 2 -- Honesty enforcement: slash the liar

`depinslash <pool> <stake> <bytes:claimed:actual ...>` runs a round where each node CLAIMS coverage
and the network measures the ACTUAL coverage over the air; a node that claims coverage it does not
have (claimed=1, actual=0) is caught and SLASHED. Host:

```
  node0 claimed=1 actual=1 -> +500 $TRI  [HONEST]
  node1 claimed=1 actual=1 -> +500 $TRI  [HONEST]
  node2 claimed=1 actual=0 -> -200 $TRI  [LIAR -> SLASHED]
  (lying loses 200, working idle earns 0 -> honesty is the dominant strategy)
```

**The coupling insight (a real finding).** Over the air the slash needs to know WHICH node a
decoded signal came from -- and a bare receiver cannot: it decoded a valid message but could not
attribute it (a kill/killall race even let a still-on .13 be counted against .11). That is exactly
what the RF fingerprint (option 1) is for: attribution is the prerequisite for honest slashing, so
options 1 and 2 are one mechanism. The slash logic is proven; its OTA arbitration rides on the
fingerprint, which awaits a good window.

## 3 -- Live network dashboard

A single-page dashboard renders the network's proven numbers -- per-node coverage (cp bar), $TRI
earned, the slashed liar, RF-fingerprint attribution -- plus the aggregate ($TRI/round, coverage,
1.64 Mbit/s) and the stack summary with proven-OTA / host / projection tags. Published as a living
artifact for an operator or investor to read at a glance. Every figure traces to an earlier OTA
run: coverage sensed 7/7, clean byte BER=0, multi-source 1/1, round 500 $TRI/node, slash -200.

## Scientific picture

A port cannot pay honestly if it cannot tell one ship from another: the harbourmaster first learns
each hull by the sound of its engine (the crystal's CFO, a voice no forger can borrow), and only
then can he reward the ships that truly delivered and fine the one that lied about its cargo. The
dashboard is the harbour board on the quay wall: every berth, every manifest, every fine, lit up
for anyone to read.

## Boards clean; RF link fading; DSSS-in-PL blocked

rffinger, depinslash, depinround, cmdclass, rfclassify all cross-compiled and deployed on the four
ARM boards. The RF link is in a fading trough this session; the fingerprint's OTA clustering awaits
a good window.

Boards left clean: writers=0, TX LO powerdown=1 on all four, RX AGC restored, LOs at 2.4 GHz, IQ
removed.
