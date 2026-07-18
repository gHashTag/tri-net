# OTA byte transfer attempt — honest status (2026-07-18)

Goal (option A): carry real bytes over the air .13 -> .12 through a software modem,
then run the Proof-of-Relay receipt over the radio-delivered bytes.

## What was built and validated

A CFO-immune differential-BPSK modem (host-side, `scratchpad/dbpsk.py`):
- Frame = 63-bit PN preamble ++ payload, one continuous DBPSK stream.
- Demod: differential detector `x[n]·conj(x[n-OSF])` (cancels carrier offset),
  correlate against the PN differential pattern for frame sync, integrate-and-dump.
- **Loopback-validated**: with simulated 2.4 kHz CFO + ~43 dB noise + a random
  capture offset, `corr_peak = 1.000`, **BER = 0/64**, payload recovered exactly.

## What happened on the real link

- TX: `.13` set TX LO 2400 MHz, DDS disabled, `iio_writedev -c` streaming one
  5120-sample frame cyclically; RX: `.12` `iio_readdev -s 65536`.
- Capture had a signal (RMS 493 vs noise floor 7.4 ≈ 36 dB, 90% of energy within
  ±1 MHz of DC) but demod gave `corr_peak ≈ 0.37`, BER ≈ random.
- **Root cause (diagnosed, not guessed):** the capture's autocorrelation at the
  frame period (lag 5120) is **0.030** — essentially zero. A cyclically transmitted
  frame would show strong periodicity there. So `iio_writedev -c` is **not putting
  the periodic frame on the air** as configured; the demod was locking onto noise.
  The failure is in the TX-cyclic bring-up (DAC DMA / DDS-core buffer mode), NOT in
  the modem DSP (which is loopback-proven).

## Honest state

- Real TX and RX paths both exercised on hardware; the 47 dB tone link (separately
  measured) confirms the RF path is healthy.
- The demod is correct (loopback BER=0). What is missing is a correctly configured
  cyclic/streaming TX of the sample buffer, or use of the existing PL DSSS PHY that
  reached BER=0 in prior work (Loop24) with proper pulse shaping + M² carrier
  estimation — a naive rectangular DBPSK through the AD9361's filtered path is the
  wrong tool anyway.
- Next: fix `iio_writedev` cyclic streaming (confirm frame periodicity at the RX
  first), or drive the PL modem; then meter the recovered bytes and close A.

Boards left clean: writers killed, TX DDS off, TX LO pd=1 on .11/.12/.13.
