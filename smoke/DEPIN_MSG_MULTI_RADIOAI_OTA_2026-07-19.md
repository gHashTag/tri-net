# A phrase, a multi-source message, and radio->AI -- all over the air (2026-07-19)

Three over-the-air milestones in one wave, all riding the fade physics measured last: the fade is
slow with long good windows, so catch a window and everything works. A whole phrase, a two-source
message, and an on-chip AI coverage decision -- all on the real 4-board rig.

## 2 -- A whole phrase over the air (not just a byte)

Last result was a 4-byte byte. This is a 16-byte message. `otatx "TRINET-OTA-LIVE!"` cyclic, caught
by selection combining over the recovered link (2.400 GHz, gain 71):

```
  try1:  copies=64  best_cp=1.000  BER=0/128  recv=5452494e45542d4f54412d4c49564521  ("TRINET-OTA-LIVE!")
```

First capture, best copy at cp=1.000, all 128 bits correct, the exact phrase. A real payload over
the fading link -- because the fade is slow, a 16-byte frame (0.25 ms) sits well inside a good
window, and selection combining over 64 copies finds the clean one.

## 1 -- A multi-source message over the air, caught in a good window

Two sources transmit ONE generation at once on different frequencies -- `.13 @ 2.400` (Vandermonde
code 0) and `.11 @ 2.404` (code 1) -- and `.10 @ 2.402` captures both with the wide-band digital
channelizer (mix +/-2 MHz) and solves GF(256):

```
  try1:  gens_decoded=1/1  mac_dropped=0   === MULTI-SOURCE MESSAGE CAUGHT OVER AIR (both bands) ===
```

Both bands, first capture. The fade physics predicted this: the fade is slow and (being at the RX
front end) common to both incoming paths, so a good window is good for both sources at once. Neither
source alone carries a full generation; together, from one capture, the destination reconstructs the
exact message. Multi-source coverage over the air, caught by waiting for the window.

## 3 -- Radio -> AI on one chip, end to end over the air

The received radio is classified by an on-chip ternary AI: three RF features (preamble correlation
cp, envelope flatness, subcarrier concentration) are ternary-quantized to {-1,0,+1} and fed through a
ternary-weight MAC (0 DSP -- the project's core primitive) to decide SIGNAL (a covered transmitter
is present) vs NOISE. This is the sensing half of Proof-of-Coverage, and it runs on the same board
that received the radio.

```
  TX ON  (5 captures):  cp=1.000 flat~0.8  -> ternary score +1  => SIGNAL (covered TX present)   5/5
  TX OFF (2 captures):  cp~0.16  flat=0.00  -> ternary score -3  => NOISE  (no coverage)          2/2
```

7 of 7 correct on real over-the-air captures. The chip hears the radio and decides, in ternary
arithmetic, whether a covered transmitter is there -- the "hear -> understand" loop the flagship
promised, closed on silicon: radio in, features, ternary MAC, a coverage verdict out. (Honest note:
the subcarrier-concentration feature is weak because the DBPSK modulation smears the tone; cp and
envelope flatness carry the decision, and the ensemble is still correct 7/7.)

## Scientific picture

The slow fade is a lighthouse beam sweeping past: dark, then a long bright pass, then dark again. Once
you know the sweep is slow, you do not curse the dark -- you wait for the beam and read everything by
its light. Under that one good pass we read a whole sentence, heard two speakers at once, and taught
the chip to answer a question it was asked in its own three-valued tongue: is someone there? Yes.

## Boards clean; DSSS-in-PL still blocked

All modes cross-compiled and deployed on the four ARM boards; otarxbest, otarxrlnc2, rfclassify,
fadeprofile, linkq and the adaptation loop run on hardware. Full DSSS despreading in the PL still
needs Vivado + ADI-HDL.

Boards left clean: writers=0, TX LO powerdown=1 on all four, RX AGC restored, LOs at 2.4 GHz, IQ
removed.
