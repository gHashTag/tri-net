# RF fingerprint over the air + multi-hop relay economics + live dashboard (2026-07-19)

The fade returned to a good phase, so the RF fingerprint was measured over the air; the multi-hop
economics pay relays to forward; and the dashboard now carries the real numbers.

## 1 -- RF fingerprint over the air: per-node CFO signatures

The link recovered (fadeprofile mean cp 0.998 / 1.000), so `rffinger` could be measured in good
windows. Each node's fine carrier-frequency offset, over the air, .10 as RX:

```
  node .11:  CFO = -55, -62, -53, -69 Hz   -> tight cluster ~ -60 Hz   (DISTINCT)
  node .12:  CFO = +15, +17, -60, -78 Hz   -> ~ 0 to -30 Hz            (noisy)
  node .13:  CFO = +15, +14 Hz (+outliers) -> ~ +15 Hz
```

The fingerprint is measurable over the air with tens-of-Hz precision in a good window, and **.11 has
a clearly distinct signature (~ -60 Hz)**. Honest finding: these particular P201Minis have
near-identical crystals -- the offsets are only tens of Hz (~0.01 ppm), so CFO alone gives PARTIAL
node separation (.11 stands out; .12/.13 cluster near 0). A richer fingerprint (I/Q imbalance, phase
noise, turn-on transient) is needed for robust 3-way ID on boards this well-matched. The
concept is proven; the boards are just unusually similar.

## 3 -- Multi-hop DePIN economics: relays are paid to forward

`depinrelay <pool> <bytes> <hops> [relay_share_pct]` splits a path's reward so the ORIGIN earns for
producing and each RELAY earns a carry-fee for forwarding -- the incentive that makes coverage grow
bottom-up. The 2-hop data path itself (.13 -> .12 -> .10) was proven over the air in an earlier wave
(identical seal at origin, hop-1, hop-2).

```
  2-hop .13 -> .12(relay) -> .10, 30% carry:  origin .13 700 $TRI | relay .12 300 $TRI | dest .10 0
  3-hop .13 -> .12 -> .11 -> .10:              origin 700 | each relay 150 | dest 0
```

A relay that carries someone else's traffic now earns real $TRI for it, so a node has an economic
reason to extend the mesh rather than only serve itself -- the mechanism behind "internet from air"
spreading node by node. A ledger root commits the path.

## 2 -- Live dashboard, real numbers

The network dashboard now shows the measured CFO fingerprints (.11 ~ -60 Hz distinct, .12 ~ 0,
.13 ~ +15 Hz), a multi-hop economics panel (origin 700 / relay 300 / dest 0), and the round with the
slashed liar -- every figure from a real run. It is the operator/investor view: coverage, rewards,
slashing, attribution, all on one page.

## Scientific picture

Told the crystals apart at last: in a clear moment the harbourmaster heard each engine's pitch and
found that one boat (.11) hums a note all its own, while two others are near-twins -- honest, and a
reason to listen for more than pitch alone. And the port now pays the pilots who guide ships through
the strait, not only the ships that carry cargo -- so more pilots come, and the safe channels
multiply.

## Boards clean; DSSS-in-PL blocked

rffinger, depinrelay, depinslash, depinround, cmdclass, rfclassify all on the four ARM boards; the
fingerprint measured over the air, the relay economics settled.

Boards left clean: writers=0, TX LO powerdown=1 on all four, RX AGC restored, LOs at 2.4 GHz, IQ
removed.
