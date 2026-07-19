# Full DePIN cycle over the air + modulation recognition + good-window forecast (2026-07-19)

The flagship loop is closed on silicon over the air: received radio -> ternary AI coverage -> Proof-
of-Relay receipt -> $TRI minted, all on the RX node. Plus a 3-class modulation recogniser and the
evidence that the good window is forecastable.

## 1 -- Sensing -> proof -> token, over the air, on one node ($TRI minted)

`depinota` runs the whole economic cycle on the receiving board from one capture: (1) selection-
combining decode of the received radio, (2) a ternary-weight AI coverage verdict, (3) a Proof-of-
Relay receipt over the decoded bytes, (4) mint $TRI -- but ONLY if coverage is real and the decode
is clean.

```
  OTA (good window):  RADIO cp=1.000 BER=0/128 | AI SIGNAL (covered) | RECEIPT acc=0x6DB8803A seal=0x845AE91B | $TRI minted=1000
  host (noise):       RADIO cp=0.083 BER=60/128 | AI NOISE           | RECEIPT ...                             | $TRI minted=0
```

Over the air, in a good window, the node decoded the phrase with zero errors, the on-chip AI
confirmed a covered transmitter is present, a fake-resistant receipt was struck over the bytes, and
the settlement layer minted $TRI. On a noise capture nothing is minted -- no coverage, no clean
data, no reward. This is the DePIN thesis end to end on hardware: coverage that is sensed, proven,
and paid, all on the same chip that heard the radio. Reproduced across two runs.

## 2 -- Modulation recognition on chip (DBPSK / TONE / NOISE)

The classifier gains a third RF feature -- differential coherence `dcoh = |mean(d)| / mean(|d|)`,
`d[k]=x[k+OSF]*conj(x[k])` -- which is CARRIER-OFFSET ROBUST (unlike a fixed-bin DFT): a pure tone's
differential is a constant vector (dcoh~1), DBPSK's flips with data (mid), noise is random (~0). It
is ternary-quantized and fed to the ternary MAC alongside the preamble correlation.

```
  host:  DBPSK dcoh=0.11 -> DBPSK-mesh    TONE dcoh=1.00 -> TONE/CW    NOISE dcoh=0.00 -> NOISE   (3/3)
  OTA:   DBPSK dcoh=0.11 -> DBPSK-mesh    TONE dcoh=0.85 -> TONE/CW    (2/2 for present signals)
```

Our own DBPSK mesh signal is recognised reliably over the air (the preamble correlation is CFO-
immune). The DBPSK-vs-other distinction -- the one the mesh needs -- is robust OTA.

**Honest boundary (a real RF artifact).** The "TX OFF" capture at RX gain 71 classifies as TONE, not
NOISE, because at high gain the receiver's own **LO leakage** is itself a coherent carrier (dcoh
~0.99). Distinguishing a real external tone from the RX's LO leakage needs a power/RSSI gate (a real
transmitter is far stronger) or a frequency check (leakage sits at DC/centre), which the current
3-feature classifier does not have. Tone-vs-noise is proven on host; OTA it is confounded by LO
leakage. DBPSK recognition -- the mesh-relevant one -- is unaffected.

## 3 -- The good window is forecastable

Because the fade is slow (last wave: cp lag-1 autocorrelation 0.58-0.96), the next frame's quality
is highly predictable from the current one. `cppredict` builds the cp series and forecasts the next
frame's decodability with a tiny ternary persistence+trend predictor. Within a good window the
series is stably high (64/64 decodable, predictor 100%); the forecastability itself is the measured
lag-1 autocorrelation -- a slow, smooth fade is a schedulable one. A node can transmit into predicted
good windows instead of blind retries. (Honest: a single 16 ms capture is uniform, so the intra-
capture prediction is trivially perfect; the cross-time evidence is the autocorrelation.)

## Scientific picture

The node is now a full lighthouse keeper: it hears the ships (radio), knows a real ship from its own
lamp's glare (modulation recognition, with the honest note that the glare can fool it at full
brightness), writes the harbour receipt, and is paid in $TRI for the coverage it proved -- and it has
learned the rhythm of its own fog, so it calls out only when the air is clear.

## Boards clean; DSSS-in-PL still blocked

All modes cross-compiled and deployed on the four ARM boards; depinota, rfclassify, cppredict,
otarxbest, fadeprofile, linkq run on hardware.

Boards left clean: writers=0, TX LO powerdown=1 on all four, RX AGC restored, LOs at 2.4 GHz, IQ
removed.
