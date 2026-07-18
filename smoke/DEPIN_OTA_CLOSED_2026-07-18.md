# OTA byte-over-the-air CLOSED — BER=0 cross-board (2026-07-18)

After many waves stuck on the OTA modem, the flagship "byte from the air" is CLOSED,
**non-destructively (no PL flash)**, with the host-side DBPSK modem.

## Result

A real 8-byte payload transmitted from node **.13** over the air at 2.4 GHz and
demodulated on node **.12**, twice, both bit-exact:

```
.13 -> .12 OTA: corr_peak=1.000 sent=54524921deadbeef recv=54524921deadbeef BER=0/64
.13 -> .12 OTA: corr_peak=1.000 sent=cafef00d12345678 recv=cafef00d12345678 BER=0/64
```

Single-board loopback (.12 TX -> .12 RX) also decodes BER=0 (autocorr@5120 = 0.993).

## Root cause (found by systematic elimination, doctrine §5)

The received data frame was never periodic (autocorr ~0.01), so nothing decoded.
Eliminated, one variable at a time:
1. **Cross-board clock offset** — ruled out: single-board loopback fails identically.
2. **Streaming chunk gaps / cyclic-buffer boundary** — ruled out: one contiguous
   `-b 102400` transfer fails the same.
3. **Buffer TX itself** — PROVEN WORKING: a 1 MHz buffer tone comes out at 1.001 MHz
   with 82% of power in-band (RMS 2518). The DAC plays the buffer at 30.72 MHz.
   (A stale-DMA transient made the very first tone test read RMS 33 = noise; a clean
   kill + re-setup fixed it.)
4. **RX capture overrun** — THE CAUSE. A large `iio_readdev -s 131072` overruns the RX
   DMA (the PS can't drain 30.72 MSa/s fast enough); dropped samples destroy the data
   frame's periodicity while leaving a narrowband tone recognizable. A SMALL capture
   (`-s 16384 -b 16384`, one DMA buffer) does NOT overrun -> the frame is received
   intact -> demod BER=0.

## The working recipe (host-side, no flash)

- **Modulation**: DBPSK on a **768 kHz subcarrier** (= 1 cycle/symbol = fs/OSF) so the
  data survives the AD9361 DC-offset block yet is transparent to the OSF-lag
  differential detector. (Baseband DBPSK dies in the DC block -- earlier wave.)
- **TX**: `iio_writedev -c -b 5120 cf-ad9361-dds-core-lpc voltage0 voltage1 < frame.iq`
  (cyclic), TX LO 2400 MHz, gain -10 dB. Kill any prior writer + sleep 1 first (stale
  DMA state breaks the next TX).
- **RX**: `iio_readdev -s 16384 -b 16384 cf-ad9361-lpc voltage0 voltage1` -- SMALL
  buffer to avoid overrun. RX LO 2400 MHz, manual gain ~50 dB.
- **Demod**: differential detector `x[n]*conj(x[n-OSF])` (CFO-immune), correlate the
  63-bit PN preamble's differential bits for frame sync, integrate-and-dump. BER=0.

## What this unblocks

The whole DePIN chain can now run over REAL RADIO: byte from the air -> Proof-of-Relay
receipt -> integrity gate/FEC/interleaver -> SNR-weighted payout -> Merkle root ->
ledger -> account proof -> slashing -> SHA-256 claim. The PL DSSS PHY (flash) is no
longer required to demonstrate over-the-air.

## Honest boundary

- 8-byte payload, one frame; scaling to long streams + throughput is the next step.
- Host-side software modem (dbpsk.py in scratchpad, not on the repo critical path); a
  hardened on-node modem (or the PL PHY for speed) is future work.
- Capture is a bounded 16384-sample burst (avoids overrun); continuous RX needs a
  drain that keeps up (lower rate, or PL-side capture).

Boards left clean: writers killed, TX LO pd=1 on .11/.12/.13, IQ files removed.
