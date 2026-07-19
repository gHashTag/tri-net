# Live 2-hop relay + $TRI over the air + richer fingerprint + RTI sensing (2026-07-19)

The multi-hop DePIN cycle closes live over the air -- a relay carries traffic and earns $TRI for it.
Plus a richer RF fingerprint (honest limit) and a passive presence-sensing seed.

## 2 -- A live 2-hop relay, over the air, and the relay is PAID

`.13 -> .12 -> .10`, both hops verified over the air (each decoded BER=0 in a good window), then the
path settled with the relay earning a carry-fee:

```
  hop1 .13 -> .12 : covered=1   (origin -> relay, BER=0)
  hop2 .12 -> .10 : covered=1   (relay -> dest, BER=0)
  settle:  origin .13 -> 700 $TRI | relay .12 -> 300 $TRI (carry-fee) | dest .10 -> 0
  ledger_root=0x1260EAFB
```

A node carried another node's traffic across the air and earned real $TRI for it. This is the whole
"internet from air grows bottom-up" mechanism, live: an origin produces, a relay forwards and is
paid, a destination settles and commits the ledger -- so a node has an economic reason to extend the
mesh, not just serve itself. The 2-hop data path was already proven byte-identical across hops in an
earlier wave; this wave runs it end-to-end with the economics attached.

## 1 -- Richer RF fingerprint (and its honest limit)

`rffinger` now emits CFO plus received amplitude, I/Q gain imbalance, and DC-leak. Per-node, over
the air, in good windows:

```
  .11:  CFO ~ -44 Hz   amp ~2760  gimb ~0.99   dc ~0.007
  .12:  CFO ~ -65 Hz   amp ~2755  gimb ~0.98   dc ~0.006
  .13:  CFO ~ +25 Hz   amp ~2760  gimb ~0.978  dc ~0.006
```

**Honest, security-relevant finding.** The amplitude, I/Q imbalance, and DC-leak are near-identical
across all three -- they are dominated by the COMMON receiver (.10), not the transmitter, so they
add little TX discrimination. Only the CFO is transmitter-specific, and it is tiny (tens of Hz,
~0.01 ppm crystal spread): .11 (~-44) and .13 (~+25) are separable, .12 (~-65) overlaps .11. So even
with four features, these particular P201Minis are RF-INDISTINGUISHABLE except for a partial CFO
split. That is worth stating plainly: a spoofer using an identical board could not be caught by RF
fingerprint alone on this hardware; robust attribution needs either more distinctive units, a
turn-on-transient feature, or a cryptographic identity (which the keyed MAC already provides).

## 3 -- RTI presence sensing (radio tomography seed)

`rtisense` measures the per-frame envelope across a capture and reports the coefficient of variation:
a steady link is smooth (low CV), a body crossing it fluctuates (high CV). Over the air on the
steady good link:

```
  RTISENSE frames=65  env_mean~2700  CV=0.001-0.007  thresh=0.15  -> quiet (пусто)
```

The steady empty channel reads QUIET with no false alarm (CV two orders below threshold). The
detector is calibrated: a varying channel (the earlier fade showed a cp std of 0.37) trips the
DISTURBANCE flag. Over one link this senses PRESENCE (a change); an N-link mesh would localize it
(true tomography). Honest boundary: the positive detection (a person actually walking through)
needs physical access to the bench to demonstrate; here the steady-quiet baseline and the
disturbance threshold are established, which is the half we can prove remotely.

## Scientific picture

The port now pays the pilot who guided a ship through the strait, and we watched him do it -- origin,
relay, dock, all over the air, the ledger sealed. We also tried to tell the boats apart by the pitch
of their engines and found them near-identical twins: an honest verdict that here the ship's papers
(the keyed MAC), not its engine note, must prove who it is. And the harbour's ropes now hum when
something crosses them -- steady when the water is empty, and ready to tremble when it is not.

## Boards clean; DSSS-in-PL blocked

rffinger, rtisense, depinrelay and the whole DePIN suite on the four ARM boards; the 2-hop relay run
live and settled.

Boards left clean: writers=0, TX LO powerdown=1 on all four, RX AGC restored, LOs at 2.4 GHz, IQ
removed.
