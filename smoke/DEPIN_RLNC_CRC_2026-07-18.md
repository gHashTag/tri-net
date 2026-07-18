# Per-frame CRC hardens the coded-frame stack (2026-07-18)

Last wave's multi-source RLNC had one honest wart: a single source decoded 1 of 3 generations
(a residual false-accept), because a corrupt over-the-air coded frame could sneak into the
solver as a wrong linear equation. This wave adds a per-frame CRC so every frame self-validates;
corrupt frames are dropped before the solver, single sources fail CLEANLY, and the decoder loses
its RANSAC/threshold crutches.

## Change (t27 crc16)

The K=4 coded frame payload grows to 12 bytes: `g:u16 | cv[4] | value:u32 | crc16:u16`, where the
CRC-16/CCITT (t27 `crc16.t27`, poly 0x1021, init 0xFFFF) covers the first 10 bytes. The receiver
recomputes the CRC over each demodded frame and DROPS any that fails -- a corrupt coded frame is
a wrong equation and must never enter the GF(256) solver. With clean frames, the decoder is now a
plain rank-4 Gaussian solve on the distinct coding vectors -- the previous RANSAC search and the
>=5-agreement threshold are gone.

## Over the air (.13 + .11 -> .10, K=4, 3 coded/source, message 48 B)

```
              BEFORE (no CRC)      NOW (per-frame CRC)
.13 ALONE     1/3 (false-accept)   0/3  crc_dropped=1   (clean)
.11 ALONE     0/3                  0/3  crc_dropped=1   (clean)
BOTH          3/3 (via RANSAC)     3/3  crc_dropped=2   -> "MULTI-SOURCE RLNC OVER AIR .11+.13"
```

`crc_dropped` > 0 on every capture shows the CRC actively rejecting real OTA-corrupt frames. Both
single sources now fail cleanly (0/3); the union still decodes the exact message (3/3). Same
result, but now CORRECT-by-construction rather than by a majority-agreement heuristic.

## Scientific picture

Before, the decoder was a detective with no way to tell a genuine clue from a planted one, so it
cross-checked stories and took the majority -- clever, but it could be fooled. The CRC is a
tamper-evident seal on each clue: a clue whose seal is broken is simply thrown away, and the
detective reasons only from intact clues. No voting, no guessing which four to trust -- just
solve from the clean equations. It is the difference between "probably right" and "provably
consistent", and it is what a real protocol needs before it carries anything that matters.

## Honest boundary

- CRC-16 admits a ~1/65536 undetected-error rate; a doubly-unlucky frame could still pass. For
  a demo this is negligible; a safety-critical link would use a wider CRC or an authenticated MAC.
- The CRC adds 2 bytes/frame (12 vs 10) -- ~20% frame-overhead at K=4; amortised at larger K.
- Sources still time-multiplexed on one channel (captured separately); concurrent FDD sources
  are the next step.
- Uses the t27 crc16 primitive; the coding stays MDS-Vandermonde over GF(256).

## DSSS on a big FPGA: still blocked

Re-scan: only .1 (router), .10/.11/.12/.13 (four P201Minis), the host. Needs Vivado + ADI-HDL.

Boards left clean: writers=0, TX LO pd=1 on .10/.11/.12/.13, IQ removed.
