# Double-parity FEC over the air: recover 2 losses per block (2026-07-18)

Last wave's single XOR parity healed at most ONE lost frame per block; blocks that lost two
stayed dropped. This wave adds a second, GF(256)-weighted parity so ANY TWO losses per block are
recoverable -- a small MDS code driven by the repo's t27 network-coding primitives.

## Scheme (rate 4/6, t27 rlnc_decode GF(256))

Each block of 4 data frames now carries two parity frames:
- **p0** = XOR of the four values (`fec_parity4`, marked seq 0xC000+g).
- **p1** = sum_i alpha^i * d_i over GF(256), alpha=2 so coefficients are [1,2,4,8] -- distinct and
  nonzero, so every 2x2 sub-system is invertible (marked seq 0xD000+g).

Recovery (`otarxstreamfec2`):
- 1 lost data frame -> p0 (XOR of parity + 3 survivors).
- 2 lost data frames (positions a,b; survivors c,d) -> per byte, subtract the survivors from p0/p1
  and solve `[1 1; alpha^a alpha^b][d_a;d_b] = [y0;y1]` with the t27 `solve_2x2` / `gf_mul` /
  `gf_inv`. Both frames reconstructed bit-exact.

Host-verified: dropping two frames OF THE SAME BLOCK healed both (heal2=1) and the receipt seal
matched the clean stream bit-for-bit (0x1BBB2554).

## Over the air (.13 -> .12, one 600-frame period per capture)

```
run1:  data_raw=367  +heal1=15 +heal2=1  -> 384/384   drops_left=0    (100% of run)
run2:  data_raw=364  +heal1=1  +heal2=1  -> 367/384   drops_left=17
run3:  data_raw=359  +heal1=17 +heal2=4  -> 384/384   drops_left=0    (4 two-loss blocks healed!)
run4:  data_raw=362  +heal1=10 +heal2=1  -> 374/384   drops_left=10
```

`heal2` fired on every capture (1-4 blocks) -- real two-erasure blocks reconstructed over the air
via the GF(256) 2x2 solve, which last wave's single parity could not touch. Best captures reach
**drops_left=0 including the two-loss blocks**. The remaining drops on bad captures are blocks
with >=3 data losses, or blocks whose parity frame itself was lost -- the honest limit of a
2-parity code.

## Scientific picture

The single checksum told you the four words' XOR: enough to fill ONE blank. Two checksums are two
different weighted sums of the same four words -- like being told both "their sum" and "their sum
where the second is doubled, the third quadrupled...". Two independent equations pin down TWO
unknowns: if two words are lost, the pair of checksums is a little 2x2 system that has exactly one
solution over the finite field. Cost: two extra frames in six (33% overhead) instead of one in
five, buying the jump from "survive one loss per group" to "survive two". This is the entry point
to full network coding (`rlnc_coding.t27`): add more independent parities, survive more losses.

## Honest boundary

- 2 parities repair <=2 erasures per block; >=3 losses (or a lost parity) still drop -- needs more
  parities (RLNC with larger generations) for heavier loss.
- 33% overhead (rate 4/6) vs 20% (single parity); adaptive parity count to the measured FER is the
  efficiency follow-on.
- The parity math uses the t27 `rlnc_decode` GF(256) primitives (gf_mul/gf_inv/solve_2x2); the
  receipt it seals is t27 (tri_depin).

Boards left clean: writers=0, TX LO pd=1 on .10/.11/.12/.13, IQ removed.
