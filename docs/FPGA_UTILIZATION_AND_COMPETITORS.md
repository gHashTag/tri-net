# FPGA Utilization Analysis + Competitive Landscape

**Date:** 2026-07-07
**Hardware:** P201Mini (XC7Z020-2CLG400I)
**Bitstream:** PlutoSDR/Kuiper (AD9361 DMA + PL Ethernet)

---

## Current FPGA Utilization (XC7Z020)

### PL resources currently used (from ADI fmcomms2/pluto reference design):

| Resource | Available | Used | % | What uses it |
|----------|-----------|------|---|--------------|
| **LUTs** | 53,200 | ~18,000 | ~34% | AD9361 DMA, AXI interconnect, PL Ethernet MAC |
| **FFs** | 106,400 | ~22,000 | ~21% | Pipeline registers, state machines |
| **BRAM (36Kb)** | 140 | ~65 | ~46% | DMA buffers, packet FIFOs, Ethernet buffers |
| **DSP48E1** | 220 | ~12 | ~5% | DDS NCO, CIC compensation filter |
| **MMCM** | 4 | 3 | 75% | AD9361 refclk, Ethernet clk, PL fabric clk |

### Free resources for TRI-NET:

| Resource | Free | Capacity |
|----------|------|----------|
| **LUTs** | ~35,000 | Enough for: AES-256 engine, BPSK/QPSK modem, mesh router |
| **FFs** | ~84,000 | Enough for: deep pipelines, large state machines |
| **BRAM** | ~75 blocks (2.7Mb) | Enough for: packet queues, routing tables, code buffers |
| **DSP48E1** | ~208 | Enough for: full OFDM FFT, FEC (Viterbi/LDPC), digital filters |
| **MMCM** | 1 | One clock domain available |

### Summary: ~35-40% used, ~60-65% free

---

## What to Add (ranked by impact)

### Tier 1: Immediate value (fits in <5% additional FPGA)

| Addition | Resource cost | Why |
|----------|-------------|-----|
| **AES-256-GCM in PL** | ~2,500 LUT, 0 BRAM, 0 DSP | Hardware crypto at line rate. Frees ARM CPU. ChaCha20 stays in software for key exchange. |
| **BPSK/QPSK modem** | ~3,000 LUT, 4 BRAM, 8 DSP | Direct FPGA modulation/demodulation. Bypasses ARM for real-time TX/RX. |
| **Packet CRC-32 engine** | ~500 LUT | Wire-speed integrity check before crypto layer. |

### Tier 2: Medium value (fits in <15% additional FPGA)

| Addition | Resource cost | Why |
|----------|-------------|-----|
| **OFDM PHY (256-point FFT)** | ~8,000 LUT, 8 BRAM, 32 DSP | 802.11-like waveform in FPGA. Enables wideband (20 MHz) mesh links. |
| **Viterbi decoder (k=7)** | ~4,000 LUT, 4 BRAM, 16 DSP | Forward error correction. Extends range by 3-6 dB. |
| **Hardware mesh router** | ~5,000 LUT, 4 BRAM | ETX routing table in BRAM. Wire-speed forwarding without ARM interrupt latency. |
| **RFDAC direct drive** | ~2,000 LUT, 4 DSP | Bypass AD9361 DDS, generate custom waveforms directly. |

### Tier 3: Advanced (fits in ~25% additional FPGA)

| Addition | Resource cost | Why |
|----------|-------------|-----|
| **LDPC decoder (5G NR mini)** | ~15,000 LUT, 16 BRAM, 64 DSP | Modern FEC. Near-Shannon performance. Enables long-range low-SNR links. |
| **DSSS despreader** | ~3,000 LUT, 8 DSP | Spread-spectrum processing gain. +10-20 dB link budget. Anti-jam. |
| **Spectrum scanner** | ~4,000 LUT, 4 BRAM | Real-time FFT of received spectrum. Enables cognitive radio / DFS. |

---

## Competitor Analysis

### 1. Meshtastic (LoRa mesh)
- **Tech:** LoRa SX1276 + ESP32, 868/915 MHz, 0.3-300 kbps
- **FPGA:** None (microcontroller only)
- **Crypto:** AES-256 (software)
- **Range:** 5-15 km (line of sight)
- **Price:** $30-120/node
- **Our advantage:** 1000x bandwidth (2-56 MHz vs 0.3-300 kHz), FPGA hardware crypto, zero-copy mesh routing
- **Our disadvantage:** Higher power (5W vs 0.1W), higher cost ($500 vs $30)

### 2. OpenWifi (open-source WiFi on FPGA)
- **Tech:** 802.11a/g/n on Xilinx Zynq, OFDM PHY in FPGA
- **FPGA:** ZC706 (XC7Z045, much larger than ours)
- **Bandwidth:** 20 MHz channels, up to 54 Mbps
- **Open source:** Fully open Verilog
- **Our advantage:** Mesh-native (ETX routing built in), ARM Linux for apps, lower cost
- **Our disadvantage:** No 802.11 compliance (our waveform is custom), smaller FPGA
- **What to learn:** Their OFDM implementation (github.com/open-sdr/openwifi)

### 3. srsRAN (software RAN)
- **Tech:** Pure software 4G/5G on x86, no FPGA
- **Bandwidth:** Up to 100 MHz (5G)
- **Hardware:** x86 server + USRP ($2000+)
- **Our advantage:** Self-contained (no PC needed), FPGA acceleration, 10x cheaper
- **Our disadvantage:** No 4G/5G compliance, lower throughput
- **What to learn:** Their schedulers and MAC layer design

### 4. AREDN (Amateur Radio Emergency Data Network)
- **Tech:** Modified WiFi on commercial routers (Ubiquiti), 2.4/5 GHz
- **FPGA:** None (Atheros SoC)
- **Mesh:** OLSR + AREDN firmware
- **Range:** 5-50 km with directional antennas
- **Our advantage:** FPGA crypto (hardware), custom waveforms, crypto-first design
- **Our disadvantage:** Less mature ecosystem, fewer deployed nodes
- **What to learn:** OLSR implementation, emergency deployment playbook

### 5. Silvus Technologies (StreamCaster)
- **Tech:** Military mobile ad-hoc mesh, 4x4 MIMO
- **FPGA:** Custom (likely Xilinx UltraScale+)
- **Range:** 1-10+ km mobile, encrypted
- **Price:** $15,000-50,000/node
- **Our advantage:** 100x cheaper, open source, customizable
- **Our disadvantage:** No MIMO 4x4, no military certification
- **What to learn:** Their swarm mesh topology, frequency hopping, anti-jam

---

## Recommended Roadmap for FPGA Additions

### Phase 1 (M2-M3): Crypto + Modem in FPGA
```
specs/aes256.t27         -> AES-256-GCM hardware engine (2,500 LUT)
specs/bpsk_modem.t27     -> BPSK/QPSK modulator+demodulator (3,000 LUT, 8 DSP)
specs/crc32_engine.t27   -> Wire-speed CRC (500 LUT)
```
Result: 40% + 11% = ~51% FPGA used. ARM freed from crypto/modulation work.

### Phase 2 (M4-M5): FEC + OFDM
```
specs/viterbi_decoder.t27 -> FEC decoder (4,000 LUT, 16 DSP)
specs/ofdm_fft256.t27     -> 256-point FFT (8,000 LUT, 32 DSP)
```
Result: ~51% + 20% = ~71% FPGA used. Enables wideband mesh links.

### Phase 3 (M6+): Cognitive Radio
```
specs/spectrum_scanner.t27  -> Real-time FFT spectrum (4,000 LUT)
specs/freq_hopper.t27       -> Frequency agility (2,000 LUT)
```
Result: ~71% + 10% = ~81% FPGA used. Anti-jam + cognitive radio.

### Ceiling: 81% leaves 19% margin for safety.
No resource exhaustion. XC7Z020 can handle all of this.

---

## Key Insight: FPGA is 60% Free

The current bitstream only uses AD9361 DMA + Ethernet MAC.
The remaining 60% is enough for:
- Hardware AES-256 (line-rate crypto)
- OFDM PHY (wideband modem)
- FEC (Viterbi/LDPC)
- Mesh routing tables
- Spectrum scanner

This is the core differentiator vs Meshtastic/AREDN (no FPGA) and srsRAN (no FPGA).

phi^2 + phi^-2 = 3
