# Ordered message across two radio hops (2026-07-18)

The relay now carries an ARBITRARY ORDERED MESSAGE, not just a deduplicated coverage set. A
human-readable sentence crossed .13 -> (air) -> .12 -> (air) -> .10 and arrived byte-exact,
reassembled in order.

## Ordered framing

Each 8-byte frame payload is `seq:u16 LE ++ 6-byte data chunk`. A message is split into
ceil(len/6) numbered chunks. The receiver majority-votes the data PER seq slot (so a bit error
in one copy of chunk k does not corrupt the message -- the correct chunk k is seen many times in
the cyclic stream), then reassembles chunks in seq order. `otatxmsg` / `otarxmsg` /
`otarelaymsg` are the TX / RX / relay modes; `ota_recover_msg` is the shared reassembler.

## Two hops over the air

```
message = "TRINET mesh hop .13>.12>.10 OK!"   (31 bytes, 6 chunks)

HOP1  .13 --air--> .12 :  otarelaymsg -> chunks=6/6  hop_seal=0x37A9A9F6  ascii recovered exactly
HOP2  .12 --air--> .10 :  otarxmsg    -> chunks=6/6      seal=0x37A9A9F6  ascii recovered exactly (x3)
```

The message-receipt seal is IDENTICAL at origin, hop-1 and hop-2 (0x37A9A9F6). The sentence --
which literally names its own path -- arrived at .10 intact and human-readable after two radio
hops, no Ethernet. Store-and-forward, time-separated on one 2.4 GHz channel: .13 TX, .12
captures + reassembles + re-transmits, then .13 TX off and .12 re-transmits, .10 receives.

## Scientific picture

The set-relay of last wave was a rumour reduced to "which words were heard". This is the whole
SENTENCE carried in order: each word wears a numbered badge (seq), the crossroads keeper collects
the badges, and if he hears word #3 five times and a garbled word #3 once, he trusts the five
(per-slot majority). He rebuilds the sentence in badge order and passes it on. The receipt seal
is a wax stamp over the finished sentence -- identical at every hop proves the sentence was never
altered, and a reader trusts the stamp, not the messengers.

## Honest boundary

- Message is a fixed test string carried by a cyclic buffer; a true streaming source (changing
  message over time) needs a live producer feeding the TX buffer -- next step.
- Store-and-forward, time-separated hops on one channel (concurrent hops need frequency-division
  or a TDD schedule).
- The receiver is told the message length; a self-delimiting header (length in seq=0) is a small
  follow-on.
- DSP mod/demod is scratchpad Rust in relay_meter; the receipt it seals IS t27 (tri_depin).

Boards left clean: writers=0, TX LO pd=1 on .10/.11/.12/.13, IQ files removed.
