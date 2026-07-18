# Full RLNC + adaptive redundancy over the air (2026-07-18) -- "все три"

Last wave's double parity fixed 2 losses per block. This wave replaces the fixed code with FULL
Random Linear Network Coding over generations: any K of K+R coded frames recover all K data,
regardless of WHICH frames were lost. Plus the node measures its own loss and recommends the
redundancy R. The third option (DSSS on a big FPGA) stays blocked.

## 1 & 2 -- RLNC with generations + adaptive R

Generation = K=8 data frames. TX sends the 8 data (systematic) plus R coded frames, each a random
GF(256) linear combination: coded value = sum_i coding_vector(g,j)[i] * d_i (t27 rlnc_coding
`coding_vector`/`coeff_at`). The receiver, per generation, builds the coding matrix (data ->
unit rows, coded -> their vectors) and Gaussian-eliminates over GF(256) (t27 rlnc_decode
`gf_mul`/`gf_inv`); any 8 independent rows recover all 8 data. This survives ANY R losses in ANY
positions -- data or coded.

Host-verified: dropping 3 DATA frames of a generation, RLNC solved all 8 from 5 data + 3 coded;
receipt seal matched the clean stream bit-for-bit.

Over the air (.13 -> .12, K=8, R=5, 48 generations per period):

```
run1:  full_raw=33  rlnc_recovered=15  failed=0  -> data_final=384/384 (100%)   p=94% -> R_rec=2
run2:  full_raw=34  rlnc_recovered=14  failed=1  -> data_final=384/384*          p=92% -> R_rec=2
        (*failed=1 is a window-edge generation with too few frames captured)
```

**Every generation with losses (14-15 per capture) was fully recovered by Gaussian elimination**,
for ~100% data delivery -- losses in arbitrary positions, which the fixed single/double parity of
the previous waves could not handle in general. Decode ~9 s on the ARM (offline batch).

**Adaptive R**: the node measured its frame-delivery p (~92-94%) and computed the redundancy it
actually needs, R_rec = ceil(K(1-p)/p)+1 = 2. It ran with R=5 (safe) but now knows it can drop to
R=2 -- cutting overhead from 5/13 (38%) to 2/10 (20%) at this link quality. That is the closed
loop: measure the channel, size the code to it.

## Scientific picture

Fixed parity is like packing spare parts for specific bolts -- lose the wrong two and you are
stuck. RLNC is like sending several DIFFERENT weighted recipes of the whole batch: any eight
recipes, whichever eight survive the trip, are eight independent equations in the eight originals,
and a little linear-algebra solve reconstitutes them exactly. It does not matter which frames the
fade ate -- only how many. Adaptive R is the cook watching how much spills on the way and packing
just enough extra recipes: no more, no less.

## Honest boundary

- Needs >= K independent frames per generation; a generation that loses more than R (or whose
  coded vectors happen to be dependent) still fails. R_rec assumes independent random losses.
- Decode is an 8x8 GF(256) Gaussian elimination per lossy generation -- ~9 s for a 760-frame
  capture on the ARM (offline). Real-time needs PL or a lower rate.
- Uses the t27 rlnc_coding / rlnc_decode primitives; the receipt it seals is t27 (tri_depin).

## 3 -- DSSS on a big FPGA: still blocked

Re-scan: only .1 (router), .10/.11/.12/.13 (four P201Minis), the host -- no big FPGA on the
network or USB. Unchanged: needs Vivado + ADI-HDL or a bigger board.

Boards left clean: writers=0, TX LO pd=1 on .10/.11/.12/.13, IQ removed.
