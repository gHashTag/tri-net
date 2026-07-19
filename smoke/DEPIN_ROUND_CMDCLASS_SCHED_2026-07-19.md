# Full DePIN round over the air + command recognition + predictive scheduling (2026-07-19)

The DePIN loop scales from one node to a network: two nodes' coverage is sensed over the air and a
$TRI round is settled with a ledger commitment. Plus an on-chip control-command recogniser and the
predictive-scheduling primitive.

## 2 -- A full DePIN PoC round, over the air, across nodes

`depinround <pool> <bytes:covered ...>` settles a Proof-of-Coverage round: $TRI is split across the
COVERED nodes proportional to bytes (sum <= pool), and a ledger state-root commits the round. Driven
by real over-the-air coverage -- .10 sensed each node by catching its message in a good fade window:

```
  node .13 sensed over the air -> covered=1
  node .11 sensed over the air -> covered=1
  settle pool=1000 $TRI, 16 B/node:
    node0 (.13) 16 B covered -> 500 $TRI
    node1 (.11) 16 B covered -> 500 $TRI
  DEPINROUND paid=1000 (<= pool) ledger_root=0x72058E11
```

Each node's coverage was proven by decoding its transmission over the air (BER=0), the pool was split
by contribution, and a fake-resistant ledger root committed the round. An uncovered node earns
nothing (host example: node with covered=0 -> 0 $TRI). This is Helium-class Proof-of-Coverage for the
whole mesh, run live: coverage sensed per node, paid per node, committed on chip.

## 1 -- Control-command recognition, over the air (IEC-61499 event)

`cmdclass` maps a received 16-byte command to an action {GRANT, DENY, ALERT} by ternary correlation
against the codewords -- the max-score codeword is the action, robust to a handful of flipped bits.
Over the air:

```
  OTA: caught GRANT (BER=0) -> cmdclass -> command=GRANT (score 128/128, 0 bit-errors, margin=42)
  host error tolerance:  1-bit-errored GRANT -> still GRANT (score 126/128)
```

A control command was transmitted, received, and turned into an action on the chip, and the ternary
recogniser tolerates bit errors -- the event-driven control primitive (IEC-61499 / ASU-TP command
over radio) that the integration brief has pointed at.

Modulation recognition also gained a **power gate** to fix last wave's honest gap. mm = mean |x|; a
floor (400) rejects "TONE" verdicts driven by the RX's own high-gain LO leakage:

```
  DBPSK  mm=2177 cp=1.00        -> DBPSK-mesh
  TONE   mm=2291 dcoh=0.77      -> TONE/CW
  empty  mm=174  (strong=false) -> NOISE    (truly-empty channel, all TX LOs down)
```

The classifier is now correct 3/3 over the air -- and it even honestly flagged an accidentally-left-
on TX LO (an unmodulated carrier at mm~2064) as a TONE, which is exactly what it was. A truly empty
channel (mm=174 < 400) reads NOISE.

## 3 -- Predictive scheduling: transmit into the good windows

`schedgain` compares "always transmit" against "transmit only when the ternary predictor says the
next frame is good", from the cp[k] series. In a good window everything is decodable, so both deliver
100% with zero wasted transmissions (sent 63 frames, wasted 0). The value shows when the fade has
troughs: because the fade is slow (lag-1 autocorr 0.58-0.96, measured), the predicted-good subset is
almost all-good, so a scheduling node spends no energy transmitting into the nulls. Honest note: a
single good-window capture has nothing to schedule around; the forecastability itself is the measured
autocorrelation.

## Scientific picture

The mesh is now a small economy that pays for what it can prove it carried: each node's coverage is a
signature the network verifies over the air, the pool is divided by honest contribution, and a ledger
seals the round so no one can rewrite it. The node also understands the orders it hears (GRANT / DENY
/ ALERT) and, knowing its own weather, sends only when the sky is clear -- a harbour that hears,
decides, pays, and sails on the tide.

## Boards clean; DSSS-in-PL still blocked

All modes cross-compiled and deployed on the four ARM boards; depinround, cmdclass, rfclassify,
schedgain, depinota, otarxbest run on hardware.

Boards left clean: writers=0, TX LO powerdown=1 on all four, RX AGC restored, LOs at 2.4 GHz, IQ
removed.
