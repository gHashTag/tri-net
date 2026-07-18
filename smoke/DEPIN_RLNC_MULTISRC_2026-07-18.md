# Multi-source RLNC -- two senders decode what neither can alone (2026-07-18)

The multipath gain of network coding, on real radio: two sources (.13 and .11) each transmit
DIFFERENT coded frames of one message; a destination (.10) that hears only one source cannot
decode, but the UNION of both sources' frames decodes the full message.

## Scheme (K=4, MDS coding vectors, t27 rlnc)

Each source emits ncoded PURE coded frames per generation (no systematic data). Coding vectors
are Vandermonde/Reed-Solomon: cv = [1, x, x^2, x^3] with x UNIQUE per frame across all sources
(x = src*16 + j + 1). Any 4 frames with distinct x are guaranteed independent (MDS), so any 4 of
the frames -- from ANY mix of sources -- recover all 4 data words. `otatxcoded <hex_msg> <src_id>
<ncoded>`; `otarxrlnc2` takes a 2nd capture file and MERGES the two sources' frame lists.

Decoder robustness for real radio:
- Demod each source's capture SEPARATELY (no IQ-concat boundary garbage), then merge.
- **Dedup by cv, majority-vote the value** (a cyclic capture gives many copies of each frame;
  clean copies beat OTA bit errors).
- **RANSAC solve**: try 4-subsets, keep the solution the MOST frames agree with, accept only if
  **>=5 agree** (the 4 solving frames trivially agree, so a genuine over-determined solution needs
  at least one MORE frame to confirm -- this rejects an under-determined single source).

## Over the air (.13 + .11 -> .10, K=4, 3 coded/source, message 48 B / 3 gens)

```
message = "MULTI-SOURCE RLNC OVER AIR .11+.13"

.11 ALONE  -> gens_decoded=0/3   (rank 3 < 4, cannot decode)
.13 ALONE  -> gens_decoded=1/3   (message unreadable; 1 gen a residual false-accept, see below)
BOTH       -> gens_decoded=3/3   -> "MULTI-SOURCE RLNC OVER AIR .11+.13"  (exact)
```

Neither source alone recovers the message; the two together recover it perfectly. That is the
multi-source / multipath coding gain: the destination does not care WHICH sender a coded frame
came from, only that it has enough independent ones.

## Scientific picture

Give two messengers three different scrambles each of the same secret. Any single messenger
carries only three scrambles -- not enough to unscramble a four-part secret. But a listener who
collects both messengers' scrambles has six, and any four independent ones reconstruct the secret
by linear algebra. It does not matter which messenger a scramble came from -- coded frames are
fungible. A mesh can therefore pool coverage from several senders and paths, and a node with a
weak link to one source fills the gaps from another.

## Honest boundary

- `.13 alone` decoded 1/3 (not 0/3): with OTA bit errors and no per-frame CRC, a garbage frame
  occasionally supplies a 5th "agreeing" equation for ONE generation. The message stays
  unreadable from one source; a 1-byte per-frame checksum would make it a clean 0/3.
- Each generation needs >K received distinct-cv frames to confirm the solution (the demo sends
  3+3=6/gen). A gen that drops to exactly 4 cv would fail the >=5 confirmation.
- Sources are time-multiplexed on one channel (captured separately); concurrent FDD sources are
  the next step.
- Uses the t27 rlnc GF(256) primitives; the coding is MDS (Vandermonde), not the LCG random
  coefficients (those turned out rank-deficient for some generations -- replaced).

## DSSS on a big FPGA: still blocked

Re-scan: only .1 (router), .10/.11/.12/.13 (four P201Minis), the host. Needs Vivado + ADI-HDL or
a bigger board.

Boards left clean: writers=0, TX LO pd=1 on .10/.11/.12/.13, IQ removed.
