# Interleaver for burst errors + OTA modem progress (2026-07-18)

## Closed: block interleaver so FEC survives burst errors (tri_ilv.t27)

A real radio channel drops errors in BURSTS (fading kills a run of adjacent
datagrams), and the single-erasure XOR-FEC (tri_fec) only fixes one datagram per
codeword -- so a burst wipes a whole codeword and FEC fails. Fix: a depth-D block
interleaver spreads consecutive transmitted datagrams across D different codewords,
so any burst of length <= D leaves at most one error per codeword -- recoverable.
(This is the "FEC groups must be interleaved" rule from the repo's own CLAUDE.md.)

`specs/tri_ilv.t27`: `ilv_tx_pos` / `ilv_orig` (a D x W block permutation, read
column-major), `ilv_codeword`. 5 invariants incl. an exhaustive bijection check over
the 32-datagram block. `relayfec3` on node .12 ARM, one 8-long burst per block:

| burst | no-interleave | interleaved |
|-------|---------------|-------------|
| 1     | 64/64         | 64/64       |
| 3     | 58/64         | 64/64       |
| 5     | 56/64         | 64/64       |
| 8     | 48/64 (2 codewords lost) | **64/64 (all recovered)** |

Interleaving (depth 8, codeword 4) makes every burst up to length 8 survivable where
plain FEC loses up to two whole codewords.

## OTA modem (A): progress, still not closed

Continued the over-the-air byte transfer. Findings this wave:
- **Root cause of last wave's failure: the AD9361 blocks DC.** Rectangular DBPSK near
  baseband (a symbol held constant for OSF samples ≈ DC) is attenuated by the chip's
  DC-offset correction, while a moving tone passes (the 47 dB tone worked). Fix: put
  the data on a **768 kHz subcarrier** (= 1 cycle/symbol, so the OSF-lag differential
  detector is transparent to it). Validated in loopback THROUGH a simulated DC-notch:
  `corr_peak = 1.000`, **BER = 0/64** (the baseband version dies there).
- **The 2.4 GHz band is clean here** (TX off -> RX RMS 7 = noise floor), and the frame
  transmits strongly (RMS ~1800 = ~48 dB). `iio_writedev -c` cyclic works for a tone.
- **Still blocked:** the received data frame is NOT periodic at the frame length
  (autocorrelation at lag 5120 ~ 0.03; a strong peak would be ~1). TX/RX sample rates
  both read 30.72 MHz. This is a TX buffer-playout issue (AD9361 TX-chain
  interpolation/FIR or streaming underrun), not the DSP (loopback-proven) or the
  channel (clean). Needs AD9361 TX-filter/rate configuration work, or use the PL DSSS
  PHY that reached BER=0 in prior work (Loop24).

Boards left clean: writers killed, DDS off, TX LO pd=1, capture files removed.
