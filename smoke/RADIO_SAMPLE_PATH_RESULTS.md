# AD9361 Sample-Level Datapath — Results (2026-07-08)

Status: PASS 3/3 boards. Closes "AD9361 sample-level TX/RX" from
docs/FULL_PROJECT_CONTEXT.md section 18 item 7 — the vendor BOOT.BIN
bitstream provides the FULL radio datapath (the Kuiper bitstream did not
probe the RX DMA core; that limitation is gone on the current SD boot).

## IIO devices (identical on .11 / .12 / .13)

```
iio:device0  ad9361-phy               (control)
iio:device1  xadc
iio:device2  cf-ad9361-dds-core-lpc   (TX DDS + DMA)
iio:device3  cf-ad9361-lpc            (RX DMA)
```

## Internal digital loopback tone test (radiates nothing)

Reused trios-mesh/radio/ad9361_loopback.sh (proven 2026-07-01) with
LO=2400000000. DDS 1 MHz complex tone on TX1, on-chip digital loopback,
65536 IQ samples captured via iio_readdev from cf-ad9361-lpc,
FFT analysis on host (trios-mesh/radio/analyze_tone.py):

| Board | LO      | fs        | Peak       | SNR      |
|-------|---------|-----------|------------|----------|
| .11   | 2.4 GHz | 30.72 MSPS| +1.000 MHz | 116.5 dB |
| .12   | 2.4 GHz | 30.72 MSPS| +1.000 MHz | 116.5 dB |
| .13   | 2.4 GHz | 30.72 MSPS| +1.000 MHz | 116.5 dB |

Loopback reset to 0 on all boards afterwards (normal RX restored).

## What this unblocks

Channel T radio Transport: the BPSK modem (trios-mesh src/modem.rs, RRC +
Barker-13 sync + carrier recovery) can now stream IQ through
cf-ad9361-dds-core-lpc / cf-ad9361-lpc buffers on every board. Next
increment: BPSK frame TX on one board -> RX on another (cabled with
attenuator preferred; 2.4 GHz ISM OTA was already exercised by the E2E
RSSI test). Digital loopback validates the digital path only; the RF
front-end path was separately evidenced by the earlier OTA RSSI delta.
