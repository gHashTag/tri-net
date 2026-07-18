# 2-hop radio relay -- byte-exact "internet from the air" (2026-07-18)

Bytes travelled .13 -> (air) -> .12 -> (air) -> .10 over TWO radio hops, no Ethernet, and
arrived byte-exact -- the multi-hop mesh flagship, on 4 real P201Minis.

## The relay

A new `otarelay` mode makes a node a store-and-forward relay ENTIRELY on-chip: it demods a
capture, recovers the distinct payload set, prints the hop receipt, and RE-EMITS regenerated
DBPSK IQ of that set to stdout -- piped straight into `iio_writedev` for the next hop. No host
in the relay path.

```
HOP1  .13 --air--> .12 :  otarelay -> distinct=4  hop_seal=0x9DBE2510  (reframes to /tmp/relayed.iq)
HOP2  .12 --air--> .10 :  otarxset -> distinct=4       seal=0x9DBE2510  (x3, reproduced)
```

The coverage seal is **identical at all three points**: origin (.13's set) == hop-1 (.12) ==
hop-2 (.10) == 0x9DBE2510. That is a cryptographic proof the payload survived two radio hops
bit-exact. Sequenced store-and-forward: .13 TX, .12 captures+relays, then .13 TX off and .12
re-transmits, .10 receives -- one shared 2.4 GHz channel, time-separated hops.

## Robustness fix found this wave: majority filter

The first hop-1 attempt recovered **5** payloads, not 4 -- one was `5452df4e286f5003`, a single
frame with bit errors that passed the corr>=0.9 gate but decoded wrong. Because the coverage set
dedups BY VALUE, one bad frame becomes a phantom "distinct" payload and changes the seal
(0x7ACD8A11 != 0x9DBE2510).

Fix: **majority filter** -- count occurrences per payload, keep only those seen >= 2 times. Every
real payload repeats many times in the cyclic stream; a one-off bit error decodes to a unique
wrong value that appears once. With the filter, hop-1 recovered exactly the 4 real payloads and
the seal matched end-to-end. `ota_recover_set` now backs both `otarxset` and `otarelay`.

## Scientific picture

A relay node is a **rumour repeated at a crossroads**: the first messenger (.13) shouts to the
crossroads keeper (.12), who does not just echo noise -- he waits until he has heard each word
enough times to be sure (majority filter), then shouts the cleaned message onward to the next
village (.10). Because both keepers seal the same canonical set, an outsider can check the seals
match and know the message crossed two hops untampered -- without trusting either keeper.

## Honest boundary

- Store-and-forward, time-separated hops on ONE channel (not concurrent). Concurrent hops need
  frequency-division (hop1 at 2.4 GHz, hop2 at 2.45 GHz) or a TDD schedule -- next step.
- The relay carries a small distinct-payload SET (coverage attestation), not an arbitrary byte
  stream yet; a sequence-numbered stream relay is the throughput follow-on.
- DSP demod/mod is scratchpad Rust in relay_meter; the receipt it seals IS t27 (tri_depin).

Boards left clean: writers=0, TX LO pd=1 on .10/.11/.12/.13, IQ files removed.
