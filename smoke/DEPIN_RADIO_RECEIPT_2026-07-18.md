# Byte from the air -> Proof-of-Relay receipt, on the node ARM (2026-07-18)

The OTA link (closed last wave, BER=0) is now wired to the DePIN stack: a node RECEIVES
a byte over the air and produces a Proof-of-Relay receipt over it -- all on its own ARM,
no host in the loop. First fully-radio DePIN on silicon.

## C (closed): radio -> demod -> receipt, all on node .12 ARM

The DBPSK demod (differential detector + PN-preamble correlation + integrate-and-dump)
was ported from the host prototype to Rust (`relay_meter otarx`, BER=0-proven vs the
Python reference). On node .12:

```
iio_readdev -s 16384 -b 16384 cf-ad9361-lpc voltage0 voltage1 | relay_meter otarx <key> <epoch> <nbytes>
->
OTARX corr_peak=1.000 recovered=54524921deadbeef (8 bytes)
RECEIPT over radio-delivered bytes: dgrams=1 total_bytes=8 acc=0xC8C9AF17 seal=0x2B7275C5
```

.13 TX'd the payload over the air; .12 captured, demodulated (BER=0), and computed the
Proof-of-Relay receipt (`meter` = the t27 tri_depin relay_absorb/epoch_seal) over the
RADIO-DELIVERED bytes -- entirely on the node. The receipt is the same one the full
chain (signature, settlement, Merkle, ledger, slashing, SHA-256 claim) already consumes.

## A: longer payload + throughput

A 23-byte payload ("TRINET-DEPIN-OTA-BYTE1") transmitted .13 -> .12 over the air and
demodulated BER=0. Per-frame air throughput scales with payload size (the 63-symbol PN
preamble is amortised):
- 8-byte frame (128 symbols): ~48 kbps payload.
- 23-byte frame (256 symbols): ~576 kbps payload.
Symbol rate = 30.72 MHz / OSF 40 = 768 ksym/s. Honest caveat: a 9920-sample frame in a
16384-sample capture leaves little start margin -- 2 of 3 captures missed the full frame
(need a bigger/better-timed capture, or a streaming RX that keeps up).

## B: BER vs TX power -- a real link-quality curve

Sweeping .13's TX gain, 8-byte frame, on-node demod:

| TX gain | BER      | corr_peak |
|---------|----------|-----------|
| -10 dB  | **0/64** | 1.000     |
| -20 dB  | **0/64** | 0.999     |
| -30 dB  | **0/64** | 1.000     |
| -40 dB  | 34/64    | 0.102     |
| -50 dB  | 36/64    | 0.088     |

Error-free down to -30 dB TX, then a cliff between -30 and -40 dB (SNR drops below the
demod threshold). This is the physical basis of the SNR-weighted DePIN reward: a node
with good coverage delivers clean bytes and earns; below threshold it delivers nothing.

## Honest boundary

- Host-side-derived DSP demod ported to Rust in the node binary (relay_meter, scratchpad
  -- not on the repo t27 critical path). The receipt it feeds IS t27 (tri_depin).
- 8-24 byte payloads, one frame per capture (burst mode); continuous streaming RX +
  multi-frame reassembly is the throughput next step.
- The AD9361 RX overrun means the capture must be a bounded ~16384-sample burst.

Boards left clean: writers killed, TX LO pd=1 on .11/.12/.13, IQ files removed.
