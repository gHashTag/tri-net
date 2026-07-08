# trios-chat: Three-Channel Mesh Chat Product Spec

**Date:** 2026-07-07
**Status:** Design + initial specs
**Anchor:** phi^2 + phi^-2 = 3

---

## Product Vision

Telegram-style messaging UX on military-grade FPGA PHY.
Three adaptive channels (T/P/V) auto-negotiate by link quality.
Nobody has both: consumer UX + hardware crypto + custom PHY.

---

## Three-Channel Architecture

```
Channel T (text)   BPSK  1200 bps   10 km   200-byte msg = 1.3 sec air
Channel P (photo)  QPSK  250 kbps    3 km   100 KB JPEG = 3.2 sec
Channel V (video)  16QAM 2 Mbps      1 km   720p live @ 500 kbps
```

### Auto-Negotiation

Node measures SNR to each neighbor:
- SNR > 20 dB: channels T + P + V active
- SNR 10-20 dB: channels T + P active
- SNR < 10 dB: channel T only

### FPGA Resource Allocation (XC7Z020, ~35k LUT / 208 DSP / 75 BRAM free)

| Block | LUT | DSP | BRAM | Spec File |
|-------|-----|-----|------|-----------|
| AES-256-GCM PL | 6k | 0 | 4 | (future) |
| BPSK/QPSK modem (T+P) | 4k | 40 | 8 | channel_t_modem.t27, channel_p_modem.t27 |
| OFDM FFT-256 + 16-QAM (V) | 12k | 80 | 20 | (future) |
| Viterbi K=5 R=1/2 | 4k | 16 | 8 | (future) |
| Reed-Solomon (255,223) | 2k | 8 | 4 | (future) |
| ETX router + link-margin | 4k | 12 | 12 | etx.t27 |
| SDR framing + preamble | 2k | 44 | 10 | channel_t_modem.t27 |
| TRNG (hardware entropy) | 0.5k | 0 | 0 | trng.t27 |
| Codec2 700 bps (voice) | 1.5k | 4 | 2 | (future) |
| GPS-PPS timestamp | 0.3k | 0 | 1 | (future) |
| **Total add** | **36.3k** | **204** | **69** | |

Note: Viterbi reduced to K=5 (16 DSP instead of 24) to fit DSP budget.
Reed-Solomon can optionally move to ARM software if DSP is tight.

---

## Competitive Positioning

| Axis | Meshtastic | Reticulum | AREDN | Silvus | **Tri-Net** |
|------|-----------|-----------|-------|--------|-------------|
| **Cost/node** | $30-120 | $50+ | $80-200 | $15-50K | **$500** |
| **Throughput** | 1-8 kbps | 150 bps-1.2 Gbps | 1-30 Mbps | 25-100 Mbps | **1.2k-2M** |
| **Encryption** | AES-128 SW | AES-256 SW | WPA2 | AES-256 HW | **AES-256 PL HW** |
| **License** | None | None | HAM required | ITAR | **None** |
| **Freq range** | Fixed (433/868/915) | Multi | 2.4/5 GHz only | 1.2-6 GHz | **70M-6G** |
| **FPGA** | No | No | No | Yes (custom) | **Yes (Zynq 7020)** |
| **PHY upgradable** | No | No | No | No (fixed) | **Yes (bitstream)** |
| **Photo** | 40 min | sec-min | sec | ms | **3 sec** |
| **Video** | Impossible | WiFi only | Yes | Native | **Live 720p** |
| **Voice** | No | No | No | Yes | **Codec2 700 bps** |

### Unfair Advantages

1. **800x faster photo than Meshtastic** (3 sec vs 40 min)
2. **Hardware crypto in PL** — line-rate, side-channel resistant, keys in BBRAM
3. **Programmable PHY** — upgrade modem without changing hardware
4. **Any frequency 70M-6G** — sub-GHz for NLOS, 2.4G for video
5. **TRNG in FPGA** — regulator-compliant entropy (vs ESP32 PRNG)
6. **Codec2 voice** — walkie-talkie mode on text channel

---

## Implementation Roadmap

### Phase 1 (W12-W14): Channel T — text-only mesh chat

```
specs/channel_t_modem.t27    BPSK modem, CRC-8, framing
specs/trng.t27               Hardware entropy for key generation
```
MVP: text messages over 3 boards, BPSK 1200 bps, AES-256-GCM.

### Phase 2 (W14-W16): Channel P — photo transfer

```
specs/channel_p_modem.t27    QPSK modem, CRC-16, Reed-Solomon
```
Adds: 100 KB photo transfer in 3.2 seconds.

### Phase 3 (W16-W20): Channel V — live video

```
specs/ofdm_fft256.t27        OFDM PHY
specs/viterbi_k5.t27         FEC decoder
```
Adds: 720p video streaming at 500 kbps within 1 km cluster.

---

## Client Application

- **Web UI on Zynq**: nginx + WebSocket, accessible via Ethernet at 192.168.1.10
- **Mobile**: USB-C OTG to P201Mini or BLE bridge
- **Features**: neighbor map with link quality, message history, file transfer
- **Compression**: WebP q=60 (30-80 KB photos), H.264 500 kbps (ffmpeg on ARM)

---

## LXMF Compatibility (Strategic)

Port LXMF wire format as application layer on Tri-Net PHY.
Reticulum users migrate for free — they get hardware crypto + custom PHY.
[github.com/markqvist/LXMF](https://github.com/markqvist/LXMF)

phi^2 + phi^-2 = 3
