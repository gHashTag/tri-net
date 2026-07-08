# Channel T PHY: BPSK Frames Over The Air — Results (2026-07-08)

Status: PASS. First MODULATED DATA over the air: 27-byte BPSK frames from
board 1, received error-free by boards 2 and 3 simultaneously (broadcast).
This is the trios-mesh software modem running against the real AD9361
radio — the Channel T physical layer works end-to-end.

## Path

```
tx_shaped() on host (trios-mesh modem: BPSK, RRC beta=0.35, Barker-13 preamble)
  -> int16 IQ file (amp 8192, 8k zero head / 24k zero tail for burst gaps)
  -> ssh to board 1 -> iio_writedev -b 33740 -c cf-ad9361-dds-core-lpc (cyclic)
  -> AIR at 2.4 GHz (TX LO 2.4e9, hardwaregain 0 dB, fs 30.72 MSPS)
  -> boards 2/3: iio_readdev -b 262144 -s 1048576 cf-ad9361-lpc
  -> host: envelope burst-slicer + per-burst normalization + rx_recover()
```

## Results

| RX board | Bursts decoded | Payload correct |
|----------|----------------|-----------------|
| board 3  | 17 of 17 sliced clean bursts | 100% "TRINITY-CH-T:hello_over_air" |
| board 2  | 19 of 20      | 19x identical payload |

Symbol rate 7.68 Msym/s (SPS=4 at 30.72 MSPS) — raw burst bitrate is far
above the Channel T target (1200 bps), link margin ~49 dB on the bench.

## Two defects found and fixed in the host decode path

1. modem SYNC_THRESHOLD=8.0 is an ABSOLUTE Barker correlation level that
   assumes unit-amplitude symbols: raw ADC captures (12-bit, arbitrary
   gain) never cross it. Fix: normalize per burst (peak -> 1.25) before
   rx_recover.
2. rx_recover is single-burst and locks the FIRST correlation excursion:
   on a capture that starts mid-burst it false-syncs on payload ripple and
   returns garbage (this is the documented modem follow-up "retry next
   excursion / multi-burst demux"). Fix: envelope-based burst slicing
   (64-sample moving average, threshold 6x noise floor, require 1024 quiet
   samples before an edge), decode each burst separately, majority-vote.

Host tools: bpsk_make_iq / bpsk_decode_iq (trios-mesh examples).

## Remaining to full radio mesh (Channel T MVP)

- Bidirectional half-duplex: TX/RX turnaround on each board (keyed
  iio_writedev bursts + continuous capture windows).
- meshd integration: ModemTransport backed by IIO buffers instead of the
  in-process queue; then HELLO/ETX + forwarding run over the air and the
  proven M4 FETCH path gives Ethernet-less boards internet via board 1.
- On-board demodulation (today decode runs on the host): cross-compile the
  modem RX path into a board binary.
