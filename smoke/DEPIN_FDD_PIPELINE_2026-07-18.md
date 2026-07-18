# Concurrent FDD 2-hop relay -- pipelined, not baton-passed (2026-07-18)

Last wave's relay was store-and-forward: the relay silenced the source before re-transmitting
(walkie-talkie, take turns). This wave the relay runs CONCURRENTLY with the source on a
different frequency -- .13, .12 and .10 are all active at the same instant (phone, both talk at
once). One AD9361 does full-duplex FDD on-chip.

## Setup (frequency-division)

```
.13  TX @ 2.40 GHz  (message, continuous)
.12  RX @ 2.40 GHz  AND  TX @ 2.45 GHz   -- both at once, one chip
.10  RX @ 2.45 GHz  (hears the relay)
message = "TRINET FDD hop 2.4>2.45 live!"  (29 B, 5 chunks)  seal=0xE0AA4F5D
```

The AD9361 ENSM mode is `fdd` (also `pinctrl_fdd_indep` available), so RX_LO and TX_LO are
independent PLLs -- confirmed by reading them back at 2.40 / 2.45 GHz.

## Two concurrency proofs

**Isolation** -- .12 recovered the full message on 2.40 GHz (chunks 5/5, seal 0xE0AA4F5D)
**while its own 2.45 GHz transmitter was running**. A board's own TX at 2.45 does NOT blind its
RX at 2.40 -- 50 MHz of frequency separation gives enough isolation on one chip.

**Hop-2 live** -- .10 (RX @ 2.45) recovered the relayed message (seal 0xE0AA4F5D, reproduced
x3) **while .13 was still transmitting on 2.40**. Both hops carry traffic at the same instant;
no collision because they are on different frequencies.

End-to-end the message-seal is identical at origin, hop-1 and hop-2 (0xE0AA4F5D) -- byte-exact
across two concurrent radio hops.

## Why it matters (scientific picture)

Baton-passing halves the usable time per hop: while the relay talks, the source must be silent,
so an N-hop chain runs at ~1/N of the link rate. FDD PIPELINING removes that: assign each hop
its own colour of light (frequency), and every hop transmits continuously -- the chain runs at
the full per-hop rate regardless of length. It is the difference between a bucket brigade that
must stop to pass each bucket and a set of parallel conveyor belts. The one-chip proof is the
key enabler: a $100 P201Mini is a full relay (listen on one band, forward on another, at the
same time) with no extra radio.

## Honest boundary

- 50 MHz spacing here; the minimum spacing before the board's own TX desenses its RX was not
  swept -- worth characterising.
- Marginal .13->.12 SNR this session needed a larger capture (20 message periods) for the
  per-slot majority vote to fill all 5 chunks; 5 periods gave 3/5. More votes = cleaner.
- Still store-and-reframe at the relay (not zero-latency cut-through); the hops are concurrent
  but the relay re-modulates a whole reassembled message.
- DSP mod/demod is scratchpad Rust in relay_meter; the receipt it seals IS t27 (tri_depin).

Boards left clean: writers=0, TX LO pd=1 on .10/.11/.12/.13, LOs restored to 2.4 GHz, IQ removed.
