# radio — AD9361 5.8 GHz PHY bring-up (tri-net#9)

First step of the drone-mesh radio-PHY: prove the AD9361 IQ datapath works at the
5.8 GHz band on the real **Puzhi P201Mini** (Zynq-7020 + AD9361), before any OFDM
modem. Uses the AD9361 **internal digital loopback** so nothing is radiated.

## Verified on hardware — 2026-07-01 ✅
```
LO=5 800 000 000 Hz   loopback=1(digital)   tone=1 MHz   fs=30.72 MHz
FFT peak: +0.999 MHz   ·   108.6 dB over noise floor   ·   clean quadrature (no image)
```
The full chain — DDS tone → TX DAC → on-chip digital loopback → RX ADC → 65 536-sample
capture → FFT — recovers the tone at exactly +1 MHz. AD9361 confirmed tunable to
5.8 GHz (range [70 MHz … 6 GHz]), IQ streaming works.

## Run it
```bash
# on the Mini (over ssh):
sh ad9361_loopback.sh                      # tunes 5.8 GHz, tone, loopback, captures /tmp/rx.dat
# pull + analyze on a host with numpy:
ssh root@<mini> 'cat /tmp/rx.dat' > rx.dat
python3 analyze_tone.py rx.dat 30720000    # -> peak tone + SNR
```
Env knobs for `ad9361_loopback.sh`: `LO`, `TONE`, `N`, `LOOPBACK` (1=digital, 2=RF).

## Next (still greenfield)
- **RF loopback** (`LOOPBACK=2`) over a real SMA cable + attenuator TX→RX — proves the
  actual RF front-end, not just the digital path. Needs external PA+LNA for range.
- Single-carrier then OFDM modem on the AD9361 sample stream (P1 #9); FEC.
- Wire the sample stream to `trios-mesh` as the radio `Transport` (M2/M3).
