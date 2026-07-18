# RLNC recode at the relay -- a message across 2 hops without the relay decoding it (2026-07-18)

The canonical network-coding win: an intermediate node forms FRESH random linear combinations of
the coded frames it received and forwards them, WITHOUT decoding, and the destination still
recovers the original message. Proven over real radio, .13 -> .12 -> .10, with a human-readable
message as the proof.

## Scheme (K=4, explicit coding vectors, t27 rlnc)

Each frame carries its own coding vector: payload (10 B) = `g:u16 | cv[4] | value:u32`. A
generation is 4 message words (16 B). The source (.13) sends 4 data (cv = unit vectors) + R coded
(cv = random, value = sum_i cv[i]*d_i over GF(256)). Because the coding vector travels WITH each
frame, any node can recombine frames algebraically:

- **Relay recode (.12, `otarecode`)**: for each generation, output M new frames, each a random
  GF(256) combination of the received frames: new_cv = sum_k beta_k*cv_k, new_value =
  sum_k beta_k*value_k. The relay NEVER solves for the data -- it only mixes coded frames.
- **Decode (.10, `otarxrlnc2`)**: collect >=4 frames with independent cv per generation and
  Gaussian-eliminate over GF(256) (t27 gf_mul/gf_inv) -> the 4 data words -> the message.

Host-verified first: source -> recode -> decode reproduced the exact message from recoded-only
frames.

## Over the air (.13 -> .12 -> .10)

```
message = "TRINET RLNC RECODE .13>.12>.10 OVER AIR OK!"  (43 B, 3 gens, K=4, R=4)

.13 source  (cyclic)              -> 24 frames on air @ 2.4 GHz
.12 otarecode: in_frames=89 gens=3 -> 24 RECODED frames (NOT decoded), re-TX @ 2.4 GHz
.10 otarxrlnc2: gens_decoded=3/3  -> "TRINET RLNC RECODE .13>.12>.10 OVER AIR OK!"  (reproduced)
```

The destination recovered the exact message from the RELAY'S recoded frames. The relay only ever
handled coded combinations -- it never reconstructed the plaintext. That is network coding: the
middle of the network does algebra on coded data, and only the endpoint decodes.

## Scientific picture

A store-and-forward relay is a postman who opens each letter, reads it, and re-writes it -- he
must understand the whole message to pass it on. An RLNC recoder is a postman handed several
sealed SCRAMBLES of the letter; he shakes them together into fresh scrambles and passes those on,
never reading a word. The recipient, given enough independent scrambles from ANY mix of senders
and relays, unscrambles the original by linear algebra. This is what lets a mesh combine paths
and sources without any relay needing to (or being able to) read the traffic -- the multipath /
multicast gain of network coding, and a privacy property for free.

## Debugging note (this session)

The OTA link first read pure noise -- traced NOT to RF but to (a) a non-cyclic source stream that
finished before the ssh-sequenced capture, and (b) a missing input file (`/tmp/t.iq`) that made
iio_writedev die instantly. A transceiver reset (`ensm_mode` sleep->fdd) cleared a stale DDS
state, and a CYCLIC source (`-b 138240`, one full generation-set period) kept the signal
continuously on air so the capture always caught it. Known-good `otatx`/`otarx` then read
corr=1.000 -- RF was fine all along.

## 3 -- DSSS on a big FPGA: still blocked

Re-scan: only .1 (router), .10/.11/.12/.13 (four P201Minis), the host. No big FPGA. Needs
Vivado + ADI-HDL or a bigger board.

Boards left clean: writers=0, TX LO pd=1 on .10/.11/.12/.13, IQ removed.
