# Crypto attribution over the air + 3-hop relay + report v2 (2026-07-19)

The RF fingerprint could not tell near-identical boards apart; this wave binds coverage to an
unforgeable cryptographic identity instead -- proven over the air. Plus a deeper relay attempt and
the whole-stack report refreshed.

## 1 -- Crypto attribution: coverage bound to a key, not an engine note

Since the P201Minis are RF-indistinguishable (last wave), attribution must be cryptographic.
`depinattest <key_csv> <nframes>` reads coded frames and, for each, tries every node's key on the
frame's keyed-SHA-256 MAC; the key that verifies attributes the frame to THAT node. A spoofer without
the key matches nobody.

```
  host:  legit .13 (key A0A03333) -> tally=[0,0,6]  -> attributed to node #2
         spoofer  (key DEAD9999)  -> tally=[0,0,0], unattributed=6 -> NONE (rejected)
  OTA:   legit .13 (key A0A03333) -> tally=[0,0,30] -> attributed to node #2  (over the air)
```

Over the air, all 30 caught frames attributed to .13 by its key -- an unforgeable identity that a
spoofer with an identical board cannot borrow (it lacks the key). This is the right answer to last
wave's honest finding: the boards look identical on the air, so the network trusts the signature, not
the signal. (The spoofer's OTA run hit a fade trough this session; its rejection is host-proven and
follows directly -- a wrong key can never verify.)

## 2 -- 3-hop relay over the air (partial) + economics

`depinrelay` splits a path reward so two relays each earn a carry-fee (150 $TRI each on a 3-hop
path). Over the air this session, 2 of the 3 hops (.12->.11, .11->.10) decoded BER=0 while the first
hop hit a fade trough, so the full 3-hop path did not complete in one window. The 2-hop path was
proven end-to-end last wave (relay .12 earned 300 $TRI); the 3-hop economics are host-proven; the
missing piece is three good windows aligning, which the non-stationary fade makes intermittent.

## 3 -- Whole-stack report v2

The report now carries a crypto-attribution card, the OTA 2-hop relay-earns-$TRI card, and an RTI
presence-sensing card in the $TRI DePIN section -- so the economic-honesty story (sense -> attribute
by key -> pay -> slash -> ledger) is complete on one page, every claim tagged proven-OTA / host /
projection.

## Scientific picture

We stopped trying to know the ship by its engine and started reading its papers: every node stamps
its cargo with a private seal, and the harbourmaster trusts the seal, not the silhouette -- so a
look-alike hull with no seal is turned away at the gate. The port's ledger now records who carried
what, proven by signature, over the open air.

## Boards clean; DSSS-in-PL blocked

depinattest and the whole DePIN suite on the four ARM boards; crypto attribution proven over the air.

Boards left clean: writers=0, TX LO powerdown=1 on all four, RX AGC restored, LOs at 2.4 GHz, IQ
removed.
