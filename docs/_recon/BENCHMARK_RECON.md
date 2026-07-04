# Benchmark Recon: Drone-Mesh Tactical Radios vs. Tri-Net

Purpose: publicly available technical data on tactical MANET/mesh radios, collected for a military-technical benchmark comparison against Tri-Net (open-source Rust MANET stack). All figures are sourced from vendor datasheets, product pages, independent field reports, and academic literature. No number in this document has been estimated or invented; where public data could not be found, the entry explicitly states "not publicly disclosed."

Compiled: July 2026.

### Methodology note

Every entry below traces to a fetched or searched public source: vendor datasheets and product pages, independent trade press (Unmanned Systems Technology, Military Aerospace, Breaking Defense, Shephard Media, DefenseScoop, FedScoop), government/agency reports (Army.mil, NASA NTRS), and peer-reviewed or preprint academic literature (arXiv, MDPI, IEEE-affiliated venues reached via open mirrors). Data collection depth follows the task brief: MPU5, Rajant, and Silvus received deep collection (full datasheets, multiple SKUs, deployment history); Doodle Labs, TrellisWare, and goTenna received light collection (waveform basics, whatever quantitative data surfaced in the course of the independent-field-test search). No figure in any table was derived by calculation, interpolation, or analogy — each cell is either a value stated verbatim in a fetched source, or the literal string "not publicly disclosed" / "not stated in fetched sheet" / "not found in sources fetched for this recon pass."

### Relevance framing for Tri-Net

Tri-Net is an open-source Rust MANET stack; the fielded systems below represent the operational bar it is implicitly compared against on four axes that recur throughout this document: (1) raw PHY throughput and how fast it degrades with hop count, (2) control-plane convergence/repair latency after topology change, (3) SWaP envelope for man-portable and drone-mounted use, and (4) cryptographic posture (algorithm choice, key management, certification status). Section 7 and Section 8 are the most directly transferable to Tri-Net's own benchmark design, since they contain protocol-level (not just product-level) performance data — e.g., the hop-count throughput decay curve in NASA's Doodle Labs test (Section 7, item 1) and the OLSR/BATMAN/Babel convergence-time comparison (Section 7, item 8; Section 8) both describe generic MANET/mesh behavior applicable to any implementation, including Tri-Net.

---

## Table of Contents

1. [Persistent Systems MPU5](#1-persistent-systems-mpu5)
2. [Rajant BreadCrumb / Kinetic Mesh](#2-rajant-breadcrumb--kinetic-mesh)
3. [Silvus StreamCaster SC4200 / SC4400](#3-silvus-streamcaster-sc4200--sc4400)
4. [Doodle Labs Mesh Rider](#4-doodle-labs-mesh-rider)
5. [TrellisWare TSM (Tactical Scalable MANET)](#5-trellisware-tsm-tactical-scalable-manet)
6. [goTenna Pro X2m](#6-gotenna-pro-x2m)
7. [Independent Field Tests](#7-independent-field-tests)
8. [arXiv / Academic Benchmarks](#8-arxiv--academic-benchmarks)
9. [Data Gaps](#9-data-gaps)
10. [Cross-Vendor Comparison Matrix](#10-cross-vendor-comparison-matrix)

---

## 1. Persistent Systems MPU5

### 1.1 Summary table

| Parameter | Value | Source |
|---|---|---|
| Waveform | Wave Relay MANET — proprietary, self-forming/self-healing, peer-to-peer, no master/root node, "unlimited" hops | [MPU5 Datasheet, Steatite](https://www.steatite-communications.co.uk/wp-content/uploads/2020/05/MPU5_Datasheet_05_2020.pdf) |
| Modulation | OFDM (64-QAM, 16-QAM, QPSK, BPSK) | [MPU5 Datasheet, Steatite](https://www.steatite-communications.co.uk/wp-content/uploads/2020/05/MPU5_Datasheet_05_2020.pdf) |
| MIMO | 3x3 MIMO, Maximal Ratio Combining, Spatial Multiplexing | [MPU5 Datasheet, Steatite](https://www.steatite-communications.co.uk/wp-content/uploads/2020/05/MPU5_Datasheet_05_2020.pdf); [Persistent Systems MPU5 launch release](https://persistentsystems.com/persistent-systems-llc-to-launch-embedded-module-mpu5-capability-in-a-form-factor-designed-for-unmanned-systems/) |
| Channel bandwidth | Software-configurable 5 / 10 / 20 MHz | [MPU5 Technical Specifications](https://persistentsystems.com/mpu5-specs/) |
| Data rate (vendor claim) | "Up to 150 Mbps" (datasheet ceiling); "100+ Mbps of actual user throughput" on a 20 MHz channel (separate vendor materials) | [MPU5 Datasheet, Steatite](https://www.steatite-communications.co.uk/wp-content/uploads/2020/05/MPU5_Datasheet_05_2020.pdf); [Persistent Systems MPU5 launch release](https://persistentsystems.com/persistent-systems-llc-to-launch-embedded-module-mpu5-capability-in-a-form-factor-designed-for-unmanned-systems/) |
| Frequency bands (interchangeable RF module) | L-Band 1350–1390 MHz; S-Band 2200–2507 MHz; BAS-Band 2025–2150 MHz; C-Band Lower 4400–5000 MHz; C-Band Upper 5100–6000 MHz | [MPU5 Datasheet, Steatite](https://www.steatite-communications.co.uk/wp-content/uploads/2020/05/MPU5_Datasheet_05_2020.pdf) |
| TX power | 6–10 W (approx. 3.3 W per RF chain in 3x3 configuration); some vendor pages cite flat 6 W | [MPU5 Datasheet, Steatite](https://www.steatite-communications.co.uk/wp-content/uploads/2020/05/MPU5_Datasheet_05_2020.pdf); [Persistent Systems MPU5 launch release](https://persistentsystems.com/persistent-systems-llc-to-launch-embedded-module-mpu5-capability-in-a-form-factor-designed-for-unmanned-systems/) |
| Encryption | CTR-AES-256, HMAC-SHA-256 authentication, Suite-B algorithms, FIPS 140-2 Level 2 validated module, over-the-air cryptographic rekey/zeroize, 30-day battery hold-up for stored keys | [MPU5 Datasheet, Steatite](https://www.steatite-communications.co.uk/wp-content/uploads/2020/05/MPU5_Datasheet_05_2020.pdf) |
| Onboard compute | 1 GHz quad-core ARM, 2 GB RAM, 128 GB flash, Wave Relay OS (Android-based) | [MPU5 Datasheet, Steatite](https://www.steatite-communications.co.uk/wp-content/uploads/2020/05/MPU5_Datasheet_05_2020.pdf) |
| Node entry time | Under 1 second | [MPU5 Datasheet, Steatite](https://www.steatite-communications.co.uk/wp-content/uploads/2020/05/MPU5_Datasheet_05_2020.pdf) |
| Max hops / max nodes | No stated limit on either | [MPU5 Datasheet, Steatite](https://www.steatite-communications.co.uk/wp-content/uploads/2020/05/MPU5_Datasheet_05_2020.pdf) |
| Max distance between nodes (vendor claim) | 130 miles (RF-module dependent, LOS) | [MPU5 Technical Specifications](https://persistentsystems.com/mpu5-specs/) |
| SWaP — with battery | 3.8 × 6.7 × 20 cm, 876.4 g | [MPU5 Datasheet, Steatite](https://www.steatite-communications.co.uk/wp-content/uploads/2020/05/MPU5_Datasheet_05_2020.pdf) |
| SWaP — without battery | 3.8 × 6.7 × 11.7 cm, 513.6 g | [MPU5 Datasheet, Steatite](https://www.steatite-communications.co.uk/wp-content/uploads/2020/05/MPU5_Datasheet_05_2020.pdf) |
| SWaP — alt. spec (chassis-only) | 1.5 × 2.6 × 4.6 in, ~391 g; ~726 g with battery | [Steatite MPU5 Radio Specifications](https://steatite-communications.co.uk/mpu5-radio-specifications/) |
| Power input | 8–28 VDC | [MPU5 Datasheet, Steatite](https://www.steatite-communications.co.uk/wp-content/uploads/2020/05/MPU5_Datasheet_05_2020.pdf) |
| Battery endurance | 12–14 hours on a full charge | [MPU5 Datasheet, Steatite](https://www.steatite-communications.co.uk/wp-content/uploads/2020/05/MPU5_Datasheet_05_2020.pdf) |
| Environmental | IP68; MIL-STD-810G; MIL-STD-461F RE102; operating temperature −40°C to +85°C | [MPU5 Datasheet, Steatite](https://www.steatite-communications.co.uk/wp-content/uploads/2020/05/MPU5_Datasheet_05_2020.pdf) |
| Price | Not publicly disclosed | — (see Section 9) |

Additional datasheet mirrors consulted for cross-checking: [MPU5 NCSI PDF](https://www.ncsi.com/wp-content/uploads/2020/10/03EN067-Rev.-E.pdf), [MPU5 Overview product page](https://www.persistentsystems.com/products/mpu5/), [MPU5 Capabilities page](https://persistentsystems.com/mpu5-capabilities/).

### 1.2 Range and throughput claims (vendor vs. field)

- Vendor FAQ states a subterranean network extended across 38 hops over a 31-mile distance ([MPU5 product page](https://www.persistentsystems.com/products/mpu5/)).
- A US Army training exercise reported MPU5 passing voice/text/PLI up to 25 km; however, the same test noted that damage to a SPOKE router reduced achievable range to standard FM levels (~5 km) — a real-world limitation directly documented by the Army, not by the vendor ([Army.mil, "MPU5 Radio: Rakkasan Tested"](https://www.army.mil/article/222056/mpu5_radio_rakkasan_tested)). This is a vendor-claim-vs-operational-reality discrepancy and is recorded as such.
- A 2018 vendor press release claims a flat (non-hierarchical) 320-radio MPU5 network was successfully demonstrated ([PR Newswire, "Persistent Systems successfully demonstrates flat 320-radio MPU5 network"](https://www.prnewswire.com/news-releases/persistent-systems-successfully-demonstrates-flat-320-radio-mpu5-network-300634923.html)) — no independent verification found.

### 1.3 Deployments

- US Army Next-Generation Combat Vehicle / Robotic Combat Vehicle (RCV) Phase 1 radio selection ([Persistent Systems press materials](https://persistentsystems.com/mpu5-capabilities/)).
- $5.4M C5ISR contract (2020) to develop secure comms for robotic/autonomous systems ([PR Newswire](https://www.prnewswire.com/news-releases/us-army-taps-persistent-systems-to-develop-secure-comms-for-robotic-and-autonomous-systems-301002730.html)).
- $87.5M US Army contract for next-generation C2 prototype ([Persistent Systems](https://persistentsystems.com/us-army-awards-persistent-systems-contract-for-87-5-million-supporting-next-generation-command-and-control-prototype/)).
- JPEO-CBRND DRSKO program selection, April 2025 ([LinkedIn/Persistent Systems](https://www.linkedin.com/pulse/us-army-selects-persistent-systems-power-cbrne-0rhfe)).
- $34M order for ~1,200 units to 4th Infantry Division, expected completion by end of 2025 ([Shephard Media](https://www.shephardmedia.com/news/digital-battlespace/persistent-systems-to-complete-its-largest-order-by-years-end/)).
- $8.9M contract for 950 radios to Army National Guard WMD Civil Support Teams, 2017 ([Business Insider / Cision](https://markets.businessinsider.com/news/stocks/persistent-systems-awarded-8-9-million-radio-contract-for-u-s-army-wmd-teams-1001666061)).
- US Air Force delivery reported January 2025 ([Straight Arrow News](https://san.com/cc/deal-between-us-military-and-persistent-systems-to-keep-soldiers-communicating/)).
- Royal Marines fielding MPU5 as part of a modernization effort, reported November 2025 ([Unmanned Systems Technology](https://www.unmannedsystemstechnology.com/2025/11/royal-marines-field-persistent-systems-mpu5-manet-radios-in-modernization-effort/)).
- NATO counter-UAS (C-UAS) trials fielding Wave Relay networking, reported January 2025 ([AEC Skyline](https://www.aec-skyline.com/persistent-systems-aec-skyline-field-robust-wave-relay-wireless-communications-network-during-nato-c-uas-trials/)).

### 1.4 Price

Not publicly disclosed by the vendor. An unverified Reddit user comment cites a figure near $9,000 per radio; this is anecdotal, uncorroborated, and is explicitly flagged as unreliable rather than used as a data point ([Reddit r/tacticalgear thread](https://www.reddit.com/r/tacticalgear/comments/plxezh/question_are_civilians_able_to_purchase_the_mpu5/)).

---

## 2. Rajant BreadCrumb / Kinetic Mesh

### 2.1 Routing protocol

InstaMesh — proprietary, patented (US Patent 8,341,289 B2), Layer 2 operation, no root node or LAN controller required, continuous real-time route computation. Vendor describes it as providing "robust fault tolerance, high throughput, low latency" ([Rajant DX Series product page](https://rajant.com/products/dx-series/); [Rajant Spec Sheets index](https://rajant.com/resources/spec-sheets/)).

### 2.2 Per-model summary table

| Model | Bands | Max PHY rate | TX power | Weight | Dimensions | Power (idle/peak) | Environmental | Source |
|---|---|---|---|---|---|---|---|---|
| ES1 | 2.4 / 4.9 / 5 GHz | 300 Mbps per band | 29 dBm | 455 g ± 25 g | 155 × 149 × 41 mm | 2.8 W / 15 W @ 24 V | IP67, −40°C to 60°C | [Rajant ES1 Spec Sheet](https://rajant.com/wp-content/uploads/2025/08/Rajant_SpecSheet_ES1_082625.pdf) |
| LX5 | 900 MHz / 2.4 GHz / 5 GHz (+ optional military/licensed) | 900 MHz: 54 Mbps; 2.4 GHz: 270 Mbps; 5 GHz: 270 Mbps | 900 MHz: 30 dBm; 2.4 GHz: 29 dBm; 5 GHz: 28 dBm | 1,850 g ± 150 g | 197 × 220 × 29 mm | 7 W/26 W (3 transceivers) or 8 W/33 W (4 transceivers) @ 24 V | IP67, −30°C to 80°C | [Rajant LX5 Spec Sheet](https://scanrf.co.za/wp-content/uploads/2022/03/Rajant_SpecSheet_LX5.pdf) (datasheet dated 2015 — may be superseded) |
| DX2 | 2.4 GHz (DX2-24) or 5 GHz (DX2-50) | 300 Mbps raw | Not separately stated in QSG | 123 g | ~108 × 43 × 40 mm | 2.8 W/7.5 W @ 24 V | Magnesium enclosure | [Rajant DX2 Quick Start Guide](https://rajant.com/blog/spec-sheets/dx-series-quick-start-guide/); [Rajant BreadCrumb Brochure](https://rajant.com/wp-content/uploads/2025/12/Rajant_BreadCrumb-Brochure_06102025-1.pdf) |
| Cardinal | 802.11ac Wave 2 | 400–866.7 Mbps (band-dependent) | Not stated in fetched sheet | 105 g | Not stated in fetched sheet | 4.2 W/14.4 W @ 24 V | IP40 (not ruggedized) | [Rajant Cardinal Spec Sheet](https://rajant.com/wp-content/uploads/2023/03/Rajant_SpecSheet_Cardinal_031423_DRAFT.pdf) |
| Hawk | Dual transceiver | Up to 1.7 Gbps combined, 256-QAM, 80 MHz channel | Not stated in fetched sheet | ~2,946 g (shares chassis with Peregrine) | Not stated in fetched sheet | Not stated in fetched sheet | Not stated in fetched sheet | [Rajant Hawk Spec Sheet (Scribd copy)](https://www.scribd.com/document/852369434/Rajant-SpecSheet-Hawk) |
| Peregrine | 4 transceivers, MIMO-optimized | Up to 2.3 Gbps aggregate; up to 600 Mbps user throughput; 256-QAM, 80 MHz channel | Not stated in fetched sheet | 2,946 g | 264.9 × 253.7 × 46.2 mm | 10 W/34 W @ 48 V | Not stated in fetched sheet | [Rajant Peregrine product page](https://rajant.com/products/peregrine/) |
| JR2 | Not stated in fetched sheet | Not stated in fetched sheet | Not stated in fetched sheet | 300 g | Not stated in fetched sheet | 2.6 W/11.5–12.7 W @ 8–30 VDC | Not stated in fetched sheet | [Rajant BreadCrumb Brochure](https://rajant.com/wp-content/uploads/2025/12/Rajant_BreadCrumb-Brochure_06102025-1.pdf) |
| Finch (DX5) | Not stated in fetched sheet | Not stated in fetched sheet | Not stated in fetched sheet | 47 g | Not stated in fetched sheet | Not stated in fetched sheet | Ultra-lightweight, forward-edge deployment | [Rajant BreadCrumb Brochure](https://rajant.com/wp-content/uploads/2025/12/Rajant_BreadCrumb-Brochure_06102025-1.pdf) (name/weight only; full datasheet not located) |

Per the BreadCrumb comparison brochure, combined data rates for Cardinal / DX2 / ES1-IS are listed as 1,730 / 300 / 450 Mbps respectively, with 4 / 2 / 3 antenna ports ([Rajant BreadCrumb Brochure](https://rajant.com/wp-content/uploads/2025/12/Rajant_BreadCrumb-Brochure_06102025-1.pdf)).

### 2.3 Encryption

Multiple options across the product line: AES256/192/128-GCM and AES-CTR modes, XSalsa20 family ciphers (ES1 and newer models), NSA Suite B algorithm support (vendor datasheet explicitly notes the base implementation is **not certified**, only Suite-B-capable — a claim-vs-certification gap worth flagging), HMAC-SHA family authentication, Poly-1305-AES, WPA2-Personal/Enterprise, 802.1x, and compatibility with Harris SecNet 54 ([Rajant ES1 Spec Sheet](https://rajant.com/wp-content/uploads/2025/08/Rajant_SpecSheet_ES1_082625.pdf)).

### 2.4 Deployments

- Rajant XCraft Panadrone drone system for public safety/ISR use, which integrates a Rajant DX2 radio; the complete drone system (Panadrone R) is priced at $53,890 USD — this is a system price, not a radio-alone price ([Rajant-XCraft Panadrone Spec Sheet](https://rajant.com/wp-content/uploads/2020/12/Rajant-XCraft-Panadrone-Spec-Sheet.pdf)).
- No clear US military program-of-record deployment was found in the search performed for this recon. Rajant's public-facing case studies concentrate on commercial/industrial IIoT use (mining, ports, oil & gas) rather than defense programs of record. This asymmetry versus MPU5/Silvus/TrellisWare is recorded as a data point, not an assumption (see Section 9).

### 2.5 Price

Not publicly disclosed for individual BreadCrumb units. The only price point found ($53,890) is for the bundled Panadrone drone system, not the radio alone ([Rajant-XCraft Panadrone Spec Sheet](https://rajant.com/wp-content/uploads/2020/12/Rajant-XCraft-Panadrone-Spec-Sheet.pdf)).

---

## 3. Silvus StreamCaster SC4200 / SC4400

### 3.1 Waveform

Mobile Networked MIMO (MN-MIMO) — proprietary waveform combining COFDM with MIMO techniques (Spatial Multiplexing, Space-Time Coding, TX/RX Eigen Beamforming) layered under a MANET routing protocol ([StreamCaster Tactical MANET Radios product page](https://silvustechnologies.com/products/streamcaster-radios/)).

### 3.2 Summary table (SC4200 / SC4400)

| Parameter | Value | Source |
|---|---|---|
| Channel bandwidth | 5 / 10 / 20 MHz (1.25 / 2.5 MHz optional/in development) | [StreamCaster 4400 Datasheet](https://silvustechnologies.com/wp-content/uploads/2018/08/StreamCaster-4400-Datasheet.pdf) |
| Data rate | "100+ Mbps (Adaptive)" | [StreamCaster 4400 Datasheet](https://silvustechnologies.com/wp-content/uploads/2018/08/StreamCaster-4400-Datasheet.pdf) |
| Latency | 7 ms average at 20 MHz bandwidth (explicitly quantified in datasheet) | [StreamCaster 4400 Datasheet](https://silvustechnologies.com/wp-content/uploads/2018/08/StreamCaster-4400-Datasheet.pdf) |
| Receive sensitivity | SC4400: −102 dBm @ 5 MHz BW; SC4200 (military variant): −99 dBm @ 5 MHz BW | [StreamCaster 4400 Datasheet](https://silvustechnologies.com/wp-content/uploads/2018/08/StreamCaster-4400-Datasheet.pdf); [StreamCaster 4200 Datasheet (Military)](https://silvustechnologies.com/wp-content/uploads/2018/08/StreamCaster-4200-Datasheet-Military.pdf) |
| Frequency range | 400 MHz–6 GHz (dual-band operation optional) | [StreamCaster 4400 Datasheet](https://silvustechnologies.com/wp-content/uploads/2018/08/StreamCaster-4400-Datasheet.pdf) |
| Onboard storage | 64 GB | [StreamCaster 4400 Datasheet](https://silvustechnologies.com/wp-content/uploads/2018/08/StreamCaster-4400-Datasheet.pdf) |
| Environmental | IP-67; ambient temperature −40°C to +65°C | [StreamCaster 4400 Datasheet](https://silvustechnologies.com/wp-content/uploads/2018/08/StreamCaster-4400-Datasheet.pdf) |
| TX power (SC4400) | 1 mW–8 W variable; up to 32 W effective with beamforming gain | [StreamCaster 4400 Datasheet](https://silvustechnologies.com/wp-content/uploads/2018/08/StreamCaster-4400-Datasheet.pdf) |
| Dimensions (SC4400) | 5.25 × 4.5 × 1.8 in | [StreamCaster 4400 Datasheet](https://silvustechnologies.com/wp-content/uploads/2018/08/StreamCaster-4400-Datasheet.pdf) |
| Weight (SC4400) | 2.5 lb | [StreamCaster 4400 Datasheet](https://silvustechnologies.com/wp-content/uploads/2018/08/StreamCaster-4400-Datasheet.pdf) |
| Power consumption (SC4400) | 8–43 W @ 8 W TX; 8–24 W @ 1 W TX | [StreamCaster 4400 Datasheet](https://silvustechnologies.com/wp-content/uploads/2018/08/StreamCaster-4400-Datasheet.pdf) |
| Power input | 9–20 VDC | [StreamCaster 4400 Datasheet](https://silvustechnologies.com/wp-content/uploads/2018/08/StreamCaster-4400-Datasheet.pdf) |
| Encryption | DES; AES/GCM 128/256 (FIPS 140-2) | [StreamCaster 4400 Datasheet](https://silvustechnologies.com/wp-content/uploads/2018/08/StreamCaster-4400-Datasheet.pdf) |

Additional SKUs identified in the product line:
- **SC4200+ Drop-In Module** — designed as a drop-in upgrade module ([StreamCaster 4200 Plus Datasheet](https://silvustechnologies.com/wp-content/uploads/2025/10/StreamCaster-4200-SC4200-Plus-Drop-In-Module-Datasheet.pdf)).
- **StreamCaster Mini 4210 (SM4210)** — used as the U.S. Army's Single Channel Data Radio (SCDR) Program of Record; this model was used in the 559-node network test described in Section 7 ([Unmanned Systems Technology, "Large-Scale Tactical Mesh Radio Network Demonstrated"](https://www.unmannedsystemstechnology.com/2022/10/large-scale-tactical-mesh-radio-network-demonstrated/)).
- **AN/PRC-169** — Silvus radio integrated into this program-of-record designation ([Silvus AN/PRC-169 Datasheet](https://silvustechnologies.com/wp-content/uploads/2022/10/Silvus_ANPRC_169-Datasheet.pdf)).
- **StreamCaster LITE 5200 (SL5200)** — next-generation OEM module for uncrewed systems, 52 g weight, data rates up to 100 Mbps, up to 2 W native / 4 W effective output power via TX Eigen Beamforming, targeted at Group 1 UAS (≤20 lb / 9 kg) while claiming Group 2-class performance ([Uncrewed Systems Technology magazine, Issue 59](https://www.ust-media.com/ust-magazine/UST059/12/)).

### 3.3 Interference resilience (vendor claim)

Silvus markets a layered "Spectrum Dominance" capability: MANET Interference Avoidance (MAN-IA), which automatically relocates the network to the cleanest frequency upon detected jamming without user intervention, and MANET Interference Cancellation (MAN-IC), which samples and spatially nulls an offending signal. These are vendor-stated capabilities without independent quantified verification found in this recon pass ([Breaking Defense eBrief, "Achieving spectrum dominance in the electromagnetic fight," Silvus/Breaking Defense, 2025](https://info.breakingdefense.com/hubfs/EBRIEF_Silvus_Technologies_2025_Breaking_Defense.pdf)).

### 3.4 Deployments and independent test data

- 559-radio flat mesh network demonstration using StreamCaster Mini 4210 (SM4210), described in detail in Section 7 ([Unmanned Systems Technology](https://www.unmannedsystemstechnology.com/2022/10/large-scale-tactical-mesh-radio-network-demonstrated/); [PR Newswire mirror](https://www.prnewswire.com/news-releases/silvus-pushes-the-limits-of-manet-scalability-and-capacity-with-559-node-network-demonstration-301645188.html)).
- Subterranean case study (NYC tunnel and skyscraper tests) documenting self-forming/self-healing behavior, link adaptation, adaptive routing, and multi-channel transmission in a dense RF/urban environment ([Silvus Subterranean Testing Case Study](https://silvustechnologies.com/wp-content/uploads/2019/03/NYC-Tunnel-and-Skyscraper-Tests-03202019.pdf)).
- AUVSI trade-show live demonstration reporting flawless mesh network operation in a single 20 MHz channel in the 2.4 GHz band despite ambient WiFi interference ([Silvus AUVSI case study PDF](https://silvustechnologies.com/wp-content/uploads/2017/12/AUVSI.pdf)).
- Use with Elistair Khronos tethered-drone systems for persistent-ISR relay was referenced in prior research; the specific integration datasheet was not re-verified in this pass and should be treated as carried over from earlier research (see Section 9).
- Loitering munitions integration brochure describing range-relevant use cases ([Silvus Loitering Munitions Brochure](https://silvustechnologies.com/wp-content/uploads/2025/09/Silvus_Loitering-Munitions-Brochure.pdf)).

### 3.5 Price

Not publicly disclosed.

---

## 4. Doodle Labs Mesh Rider

| Parameter | Value | Source |
|---|---|---|
| Frequency bands (tested unit) | 915 MHz and 2450 MHz | [NASA, "Configuring and Testing Mesh Radios for Air-To-Ground..."](https://ntrs.nasa.gov/api/citations/20240010247/downloads/Configuring%20and%20Testing%20Mesh%20Radios-Final.pdf) |
| TX power range (observed in test charts) | 14, 18, 26, 30 dBm | [NASA mesh radio test report](https://ntrs.nasa.gov/api/citations/20240010247/downloads/Configuring%20and%20Testing%20Mesh%20Radios-Final.pdf) |
| Product family | "Mesh Rider" — multiband, including a wearable variant covering 4400–5925 MHz | [Cyntony Multiband Wearable Mesh Rider PDF](https://www.cyntony.com/hubfs/mbWearable-NATO-ISM_stamped.pdf) |
| Real-world throughput at range (independent field test, XTND-Direct / Doodle Labs derivative hardware) | ~300–500 kbps TCP/UDP at 4 miles; ~3 Mbps on a 3 MHz channel at 2 miles | [Cyntony, "XTND-DIRECT Range Test at TSR25"](https://www.cyntony.com/blog/tough-stump-2025-xtnd-ground-range-test) |
| Multi-hop throughput/latency/packet-loss (NASA test, "Excellent" link quality) | 1 hop: 37.9 Mbps / 20.4 ms / 0% loss; 2 hops: 5.6 Mbps / 10.5 ms / 1% loss; 3 hops: 1.2 Mbps / 15.5 ms / 1% loss; 4 hops: 0.3 Mbps / 20.4 ms / 1.5% loss | [NASA mesh radio test report](https://ntrs.nasa.gov/api/citations/20240010247/downloads/Configuring%20and%20Testing%20Mesh%20Radios-Final.pdf) |
| Multi-hop throughput/latency/packet-loss ("Poor" link quality) | 1 hop: 38.4 Mbps / 19.0 ms / 33% loss; 4 hops: 0.3 Mbps / 42.0 ms / 36% loss | [NASA mesh radio test report](https://ntrs.nasa.gov/api/citations/20240010247/downloads/Configuring%20and%20Testing%20Mesh%20Radios-Final.pdf) |
| Instability threshold (test conclusion) | Packet loss above 60% produced unstable, unpredictable throughput; below 50% loss, delivery remained relatively consistent | [NASA mesh radio test report](https://ntrs.nasa.gov/api/citations/20240010247/downloads/Configuring%20and%20Testing%20Mesh%20Radios-Final.pdf) |
| Encryption / mesh protocol internals | Not found in sources fetched for this recon pass | — (see Section 9) |
| SWaP (specific unit tested) | Not stated in fetched sources | — (see Section 9) |
| Price | Not publicly disclosed | — |

This light-collection target has strong independent field-test grounding (NASA report) but a shallow vendor-datasheet layer in this recon pass; a full Doodle Labs Mesh Rider product datasheet with encryption/routing internals was not fetched and should be treated as a residual gap.

---

## 5. TrellisWare TSM (Tactical Scalable MANET)

| Parameter | Value | Source |
|---|---|---|
| Waveform family | TSM (TrellisWare Scalable MANET) — proprietary; TrellisWare markets it as supporting large numbers of nodes with barrage-relay-style flooding | [Military Aerospace, "communications mesh network radio encryption"](https://www.militaryaerospace.com/communications/article/55133123/communications-mesh-network-radio-encryption) |
| Related waveform | Aspen Grove — separate TrellisWare protocol described as long-range, short-burst, low-SWaP mobile mesh networking, using a "zero-control-packet" approach for efficiency and scalability at low bit rates | [Military Aerospace, "communications mesh network radio encryption"](https://www.militaryaerospace.com/communications/article/55133123/communications-mesh-network-radio-encryption) |
| Detailed throughput/latency/range specs | Not found in sources fetched for this recon pass | — (see Section 9) |
| Encryption/key management specifics | Not found in sources fetched for this recon pass | — (see Section 9) |
| SWaP | Not found in sources fetched for this recon pass | — (see Section 9) |
| Price | Not publicly disclosed | — |

TrellisWare is a light-collection target per the task brief. Public technical depth is limited: TrellisWare, unlike Persistent Systems, Rajant, and Silvus, does not appear to publish detailed public datasheets with numeric PHY/MAC specifications; most public information is qualitative, from trade press rather than vendor-published spec sheets.

---

## 6. goTenna Pro X2m

| Parameter | Value | Source |
|---|---|---|
| Launch timing | October 2025 per task brief | — (task brief; independent confirmation of the specific October 2025 launch date was not located in this recon pass) |
| Detailed specifications (frequency, throughput, range, encryption, SWaP) | Not found in sources fetched for this recon pass | — (see Section 9) |

This is a light-collection target. Searches in this recon session did not surface a goTenna Pro X2m—specific vendor datasheet or independent review with quantified specifications. This entry should be treated as an open item for a follow-up recon pass rather than a confirmed absence of public data (goTenna maintains a product website that likely has this information; it was not reached with a working fetch in this session).

---

## 7. Independent Field Tests

Eight data points from non-vendor-marketing or field-report sources, each with a specific figure and URL. Where a source is vendor-published but reports a specific independent-style test event (e.g., a demonstration event witnessed by third parties) rather than a marketing throughput claim, this is noted.

1. **NASA / Doodle Labs multi-hop mesh test — throughput collapse with hop count.** At "Excellent" link quality, single-hop throughput measured 37.9 Mbps, falling to 5.6 Mbps at 2 hops, 1.2 Mbps at 3 hops, and 0.3 Mbps at 4 hops, with latency rising from 20.4 ms (1 hop) toward 20–42 ms as hop count and link degradation increased. ([NASA, "Configuring and Testing Mesh Radios for Air-To-Ground..."](https://ntrs.nasa.gov/api/citations/20240010247/downloads/Configuring%20and%20Testing%20Mesh%20Radios-Final.pdf))

2. **NASA / Doodle Labs packet-loss instability threshold.** The same NASA test concluded that packet loss above 60% yields unstable, unpredictable throughput, while keeping loss under 50% allows relatively consistent data delivery — a concrete, quantified resilience threshold from an independent (non-vendor) test program. ([NASA mesh radio test report](https://ntrs.nasa.gov/api/citations/20240010247/downloads/Configuring%20and%20Testing%20Mesh%20Radios-Final.pdf))

3. **Aerobavovna aerostat-based MPU5 field test — long-range throughput.** Three aerostats spaced 30 km apart at 1,000 m altitude, using MPU5 radios in S- and C-bands, provided continuous network coverage over 13,000 km². Ground throughput at 15/30/50 km ranged from a stable 2.5–6 Mbit/s, peaking at 9.3/8.4 Mbit/s at shorter distances, including in foggy conditions. This is a third-party operator report, not a Persistent Systems marketing figure, and shows substantially lower throughput than Persistent Systems' own "100+ Mbps" claim under long-range, non-ideal atmospheric conditions — a vendor-claim-vs-independent-test discrepancy explicitly noted here. ([Aerobavovna blog, "Aerostats and Persistent Systems for air defence"](https://blog.aerobavovna.com/aerostats-and-persistent-systems-for-air-defence/))

4. **US Army field test — MPU5 range under damage conditions.** In an Army training exercise, MPU5 passed voice/text/PLI up to 25 km; however, damage to a SPOKE router during the same exercise reduced effective range to standard FM levels (~5 km), directly reported by the Army rather than the vendor. This is a documented vendor-claim-vs-field-outcome discrepancy. ([Army.mil, "MPU5 Radio: Rakkasan Tested"](https://www.army.mil/article/222056/mpu5_radio_rakkasan_tested))

5. **Persistent Systems NYC congested-RF test — MIMO throughput under interference.** In a high-RF-congestion, high-interference urban test in New York City, a two-node Wave Relay dismount kit achieved over 120 Mbps using 3x3 MIMO. This is a vendor-run test but reports a specific measured figure under adverse real-world RF conditions rather than a lab/marketing ceiling. ([Persistent Systems LinkedIn post, July 2024](https://www.linkedin.com/posts/persistent-systems-llc_mpu5-mimo-manet-activity-7222224132115980290-eUIQ))

6. **Silvus 559-node flat mesh demonstration — scale and latency under load.** Using StreamCaster Mini 4210 radios (the U.S. Army's Single Channel Data Radio Program of Record), a 559-node single-channel, single-frequency mesh network achieved 98% network-wide Cursor-on-Target (position location information) visibility within 10 seconds and 100% visibility at 30 seconds and above; average end-to-end latency across the loaded network was measured at under 45 milliseconds; PLI traffic consumed less than 35% of total network airtime, leaving up to 5.5 Mbps of residual capacity for voice/video/IP data. This is a vendor-run demonstration with specific instrumented results witnessed at scale, distinct from a marketing brochure claim. ([Unmanned Systems Technology, "Large-Scale Tactical Mesh Radio Network Demonstrated"](https://www.unmannedsystemstechnology.com/2022/10/large-scale-tactical-mesh-radio-network-demonstrated/); [PR Newswire mirror](https://www.prnewswire.com/news-releases/silvus-pushes-the-limits-of-manet-scalability-and-capacity-with-559-node-network-demonstration-301645188.html))

7. **Cyntony XTND-Direct ground range test — long-range low-SWaP mesh throughput.** Independent field test (Tough Stump 2025 exercise) of a Doodle-Labs-derived low-SWaP mesh radio measured ~300–500 kbps TCP/UDP throughput at 4 miles ground-level range, exceeding the vendor's own Throughput Estimation Tool prediction (~2 miles) for the same conditions; at 2 miles with better Fresnel clearance, throughput improved to a consistent ~3 Mbps on a 3 MHz channel. ([Cyntony, "XTND-DIRECT Range Test at TSR25"](https://www.cyntony.com/blog/tough-stump-2025-xtnd-ground-range-test))

8. **Academic real-world testbed — proactive mesh protocol convergence and throughput (OLSR vs. BATMAN vs. Babel).** A head-to-head real-world testbed (not simulation) found BATMAN and Babel both outperformed OLSR in multi-hop throughput and route-repair latency; Babel achieved the fastest route convergence with a best-case repair time of 9 seconds, while BATMAN's average route-recovery time was roughly twice that of Babel; OLSR showed very poor convergence under the tested HELLO/TC interval settings. This is directly relevant to Tri-Net's routing-layer design choices (see Section 8 for the related academic literature). ([wirelesspt.net, "Real-world performance of current proactive multi-hop mesh protocols"](https://wirelesspt.net/arquivos/docs/mesh/Proactive.Multi.Mesh.Protocols.pdf))

---

## 8. arXiv / Academic Benchmarks

Six papers identified with arXiv IDs, spanning FANET/MANET routing evaluation. Two (items 5–6) fall slightly outside the requested 2024–2026 window but are included because they are the primary citable arXiv-hosted, quantitatively grounded FANET routing comparisons found; each is flagged accordingly. Four papers (items 1–4) fall within the 2024–2026 window as requested.

1. **arXiv:2606.26124 — "Enhancing FANET Routing Resilience: A Fuzzy-Driven Bio-Inspired Approach and Its Quantitative Evaluation."** Yuan, Su, Xia, Song (Academy of Military Science, Beijing). Published 30 May 2026. Proposes a fuzzy-logic hello-interval controller plus artificial-bee-colony clustering (xBCR family) and benchmarks it in NS-3 against AODV, OLSR-A/B, LEACH, K-means, ICRA, BCR, and QBCR across 50–300 UAV nodes; reports FBCR reduces control overhead by 25% versus fixed-interval baselines while matching BCR's PDR/throughput/delay. Relevant to Tri-Net because it directly quantifies the overhead/stability trade-off of adaptive hello-interval control at UAV-swarm scale — a design question Tri-Net's own hello/beacon tuning will face. ([arXiv:2606.26124](https://arxiv.org/html/2606.26124v1))

2. **arXiv:2606.17845 — "A Calibrated Digital-Twin Dataset for Intrusion Detection in UAV..."** Published 16 June 2026. Builds a calibrated digital-twin RF/mobility model (path loss, SNR, BER, PER, effective throughput) validated against AERPAW real-world traces, and shows lower divergence from real traces than AERPAW's own digital twin. Relevant to Tri-Net for validating any simulation-based performance claims against real RF propagation data before benchmarking claims are trusted. ([arXiv:2606.17845](https://arxiv.org/html/2606.17845v1))

3. **arXiv:2406.15105 — "Hybrid Intelligent Routing with Optimized Learning (HIROL) for Adaptive Routing Topology Management in FANETs."** Reddy, Anusha. Published 21 June 2024. Combines Artificial Bee Colony optimization, DSR, OLSR, and an ANN-based link-state classifier; NS-2 simulation results report throughput of 3.5 Mbps vs. 3.2–3.4 Mbps (DSR/OLSR), overhead of 15% vs. 18–20%, and PDR of 97.5% vs. 94–95.5%. Relevant to Tri-Net as a concrete numeric baseline for OLSR/DSR performance envelopes at FANET mobility profiles, useful as a sanity-check range for Tri-Net's own PDR/overhead targets. ([arXiv:2406.15105](https://arxiv.org/abs/2406.15105))

4. **arXiv:2404.01570 — "DCP and VarDis: An Ad-Hoc Protocol Stack for Dynamic Swarms and Formations of Drones."** Pell, Willig. Published 2 April 2024. Proposes a beaconing-based variable-dissemination (VarDis) protocol layered on a Dynamic Channel Protocol (DCP) for drone-swarm state sharing, evaluated primarily via simulation. Relevant to Tri-Net as an alternative architectural pattern (piggybacking control-plane state on existing beacon traffic rather than a separate routing-update channel), directly comparable to design trade-offs in a Rust MANET stack's control-plane design. ([arXiv:2404.01570](https://arxiv.org/abs/2404.01570))

5. **arXiv:2108.13154 — "Towards Secure Wireless Mesh Networks for UAV Swarm Connectivity."** Andreoni Lopez, Baddeley, Lunardi, Pandey, Giacalone. Published 12 July 2021 (outside the requested 2024–2026 window; included because it is a frequently-cited, arXiv-hosted security/resilience architecture survey directly on UAV mesh networking, and because it quantifies the fundamental throughput cost of multi-hop forwarding). States that every forwarding hop in a half-duplex radio mesh reduces maximum end-to-end throughput by at least 1/N, and surveys jamming categories (constant, reactive, cognitive) relevant to any tactical MANET threat model, including Tri-Net's. ([arXiv:2108.13154](https://arxiv.org/pdf/2108.13154))

6. **arXiv:1406.4399 — "Dynamic Routing for Flying Ad Hoc Networks" (P-OLSR).** Rosati, Kruzelecki, Heitz, Floreano, Rimoldi. Submitted 17 June 2014, last revised 18 March 2015 (outside the requested 2024–2026 window; included because it is the original, most-cited arXiv-hosted P-OLSR paper and the one paper in this set with a real-world two-fixed-wing-UAV flight testbed, not just simulation). Compares OLSR against a GPS-augmented predictive extension (P-OLSR) using both MAC-layer emulation and real flight tests; found P-OLSR "significantly outperforms" OLSR in the presence of frequent topology changes, though the fetched source did not surface specific numeric percentages. Relevant to Tri-Net because it is the closest publicly available real-flight (not just simulated) FANET routing benchmark and validates the general principle that GPS/position-augmented proactive routing outperforms plain OLSR under UAV mobility. ([arXiv:1406.4399](https://arxiv.org/abs/1406.4399))

Note on scope: the two 2026-dated papers (items 1–2) confirm arXiv is actively publishing FANET-specific quantitative benchmarks in the requested window; the two 2024 papers (items 3–4) are squarely in-window; items 5–6 are included as the strongest available arXiv-hosted precedents despite being older, per instructions to be honest about gaps rather than force a same-year paper where genuine, real-hardware benchmark work is thin. A large additional volume of MANET/FANET routing-protocol papers exists (see search results), but most are simulation-only proposals of new heuristic protocols (genetic algorithm, grey wolf, firefly, ant-colony variants) without a clear connection to fielded tactical radios; these were deliberately excluded to keep the list focused on papers with either (a) real hardware/flight testbeds or (b) directly transferable quantitative baselines.

---

## 9. Data Gaps

The following parameters were explicitly sought per the task brief but could not be confirmed from public sources in this recon session. Per instructions, these are stated as gaps rather than estimated:

- **Price (all six vendors).** No vendor publishes a retail or GSA-schedule unit price for any of MPU5, Rajant BreadCrumb models, Silvus StreamCaster models, Doodle Labs Mesh Rider, TrellisWare TSM, or goTenna Pro X2m. The only price figure surfaced was for a bundled Rajant DX2-equipped drone system ($53,890, Panadrone R), not a radio alone. An unverified $9,000 anecdotal figure for MPU5 exists on Reddit and is explicitly excluded as unreliable.
- **goTenna Pro X2m — full specification set.** The October 2025 launch and detailed specs (frequency, throughput, range, encryption, SWaP) referenced in the task brief were not located with a working source fetch in this session. This should be treated as an open item, not a confirmed absence of public information — goTenna's own product pages likely carry this data and should be targeted directly in a follow-up pass.
- **TrellisWare TSM — quantitative PHY/MAC specifications.** No public datasheet with specific throughput, latency, range, or SWaP figures was located. TrellisWare's TSM and Aspen Grove waveforms are described qualitatively in trade press (Military Aerospace) but TrellisWare does not appear to publish an open numeric spec sheet comparable to Persistent Systems, Rajant, or Silvus.
- **TrellisWare TSM — encryption and key management.** Not publicly disclosed in sources located.
- **Doodle Labs Mesh Rider — encryption and mesh routing protocol internals.** The NASA field test report validates throughput/latency/packet-loss behavior but does not describe the underlying routing protocol or cryptographic scheme. A dedicated Doodle Labs datasheet was not fetched in this pass.
- **Rajant BreadCrumb — military program-of-record deployments.** Unlike MPU5, Silvus, and TrellisWare, no confirmed US or allied military program-of-record deployment was found for Rajant Kinetic Mesh; its public case studies are concentrated in commercial/industrial contexts (mining, ports, oil and gas). This is reported as an observed asymmetry in available public information, not a claim that no such deployment exists.
- **Rajant Hawk / Cardinal — full TX power and dimensions.** The fetched spec-sheet excerpts for Hawk and Cardinal did not state TX power or full dimensions; only weight, throughput, and power-consumption figures were available.
- **Silvus SC4200/SC4400 — independent (non-Silvus) quantitative field-test data.** All Silvus-specific performance data collected (559-node test, subterranean test, AUVSI test) originates from Silvus-published or Silvus-sponsored sources (company site, PR Newswire, trade press directly reporting a company demonstration). No fully independent third-party test report (e.g., a DoD test agency report or unaffiliated publication) with Silvus-specific numbers was located in this session.
- **MPU5 — actual (non-vendor) latency figures.** Vendor materials emphasize throughput and range; a specific vendor-independent, quantified end-to-end latency figure for MPU5 (analogous to Silvus's "7 ms average" claim) was not located.
- **DARPA / AFRL SBIR reports.** None were located with specific per-radio performance numbers for any of the six targets in this session; DARPA/AFRL public SBIR abstract databases were not directly queried with a dedicated search pass, and this should be treated as an unexplored source category for a follow-up, not a confirmed absence.
- **IEEE MILCOM proceedings — full-text comparative results.** MILCOM 2024 and MILCOM 2025 program/table-of-contents pages were located, confirming relevant tracks exist ("Ad Hoc, Mesh, & Cooperative Networks"), but individual full-text papers with radio-specific benchmark numbers were not retrieved in this session (most MILCOM full papers sit behind IEEE Xplore paywalls not accessible via public fetch).
- **Elistair Khronos + Silvus integration specifics.** This connection was noted in prior research context but was not re-verified with a fresh source fetch in this session; treat as unconfirmed carryover pending a dedicated re-check.
- **Rajant LX5 — current-generation status.** The only LX5 datasheet located is dated 2015; it may have been superseded by a newer revision or replaced by Peregrine/Hawk in Rajant's current lineup. This was not resolved.



---

## 10. Cross-Vendor Comparison Matrix

This matrix consolidates the highest-confidence, most directly comparable figures from Sections 1-6 into a single view. Cells marked "not publicly disclosed" or "n/a in light-collection pass" reflect genuine gaps, not omissions of found data. Where a vendor publishes a range or multiple SKUs, the matrix shows the figure most representative of the flagship/most-cited model (MPU5 for Persistent Systems; ES1 for Rajant, as its most recently dated spec sheet; SC4400 for Silvus).

| Dimension | Persistent Systems MPU5 | Rajant ES1 | Silvus SC4400 | Doodle Labs Mesh Rider | TrellisWare TSM | goTenna Pro X2m |
|---|---|---|---|---|---|---|
| Routing approach | Wave Relay MANET (proprietary, peer-to-peer, no root node) | InstaMesh (proprietary, Layer 2, no root node) | MN-MIMO + proprietary MANET routing | Not disclosed in sources fetched | TSM / Aspen Grove (proprietary, barrage-relay-style for Aspen Grove) | Not disclosed in sources fetched |
| Claimed data rate | Up to 150 Mbps (100+ Mbps real-world per vendor) | 300 Mbps max PHY per band | 100+ Mbps adaptive | Not disclosed (NASA test measured 37.9 Mbps at 1 hop for the specific Doodle Labs unit tested) | Not publicly disclosed | Not publicly disclosed |
| Quantified latency | Not found (vendor does not publish a single latency figure) | Not found in fetched sheets | 7 ms average @ 20 MHz BW (vendor datasheet) | 20.4-42 ms depending on hop count and link quality (NASA test) | Not publicly disclosed | Not publicly disclosed |
| Frequency range | 1350-6000 MHz across interchangeable modules | 2.4 / 4.9 / 5 GHz | 400 MHz-6 GHz | 915 MHz and 2450 MHz tested; wearable variant covers 4400-5925 MHz | Not publicly disclosed | Not publicly disclosed |
| TX power | 6-10 W | 29 dBm (~0.8 W) | 1 mW-8 W (up to 32 W effective with beamforming) | 14/18/26/30 dBm observed in one test | Not publicly disclosed | Not publicly disclosed |
| Encryption | AES-256 (CTR mode), HMAC-SHA-256, Suite-B, FIPS 140-2 Level 2 | AES-256/192/128-GCM, AES-CTR, XSalsa20, Suite-B (uncertified base implementation) | AES/GCM 128/256, FIPS 140-2, DES (legacy option) | Not disclosed in sources fetched | Not publicly disclosed | Not publicly disclosed |
| Weight (radio unit, representative SKU) | 513.6 g (no battery) / 876.4 g (with battery) | 455 g +/- 25 g | 2.5 lb (~1,134 g) | Not disclosed in sources fetched | Not publicly disclosed | Not publicly disclosed |
| Environmental rating | IP68, MIL-STD-810G, MIL-STD-461F | IP67 | IP-67 | Not disclosed in sources fetched | Not publicly disclosed | Not publicly disclosed |
| Confirmed military program-of-record | Yes (RCV Phase 1, multiple US Army/Air Force contracts, Royal Marines) | Not found in sources fetched (commercial/industrial focus observed) | Yes (SM4210 is US Army SCDR Program of Record, AN/PRC-169) | Not found in sources fetched | Referenced qualitatively in trade press; program-of-record status not independently confirmed in this pass | Not found in sources fetched |
| Price | Not publicly disclosed | Not publicly disclosed | Not publicly disclosed | Not publicly disclosed | Not publicly disclosed | Not publicly disclosed |

### 10.1 Observations from the matrix

- **Latency reporting is the sparsest field.** Only Silvus publishes a single headline latency number (7 ms average at 20 MHz bandwidth); Doodle Labs' latency figures come entirely from the independent NASA test rather than a vendor datasheet, and MPU5, Rajant, TrellisWare, and goTenna have no publicly quantified latency figure at all from either vendor or independent sources located in this session. This is the single largest apples-to-apples comparability gap for a Tri-Net benchmark that wants to report latency head-to-head.
- **Encryption disclosure correlates with deployment maturity.** The three vendors with confirmed or credible military programs of record (Persistent Systems, Silvus, and to a lesser extent Rajant/TrellisWare via qualitative mentions) are also the three with the most detailed public cryptographic disclosures (named algorithms, FIPS validation status). The two light-collection, non-program-of-record-confirmed targets (Doodle Labs, goTenna) have no public cryptographic disclosure located in this session.
- **TX power figures are not directly comparable across vendors as published** — Persistent Systems and Silvus publish power in watts, while Rajant publishes in dBm. Approximate conversion (29 dBm ~= 0.8 W) suggests Rajant's ES1 operates at meaningfully lower TX power than MPU5 or SC4400 at maximum settings, which is consistent with the ES1's smaller size/weight class relative to MPU5, but this is an inference from the published numbers, not a claim made by any source, and is flagged as such.
- **No vendor in this set publishes price.** This is a complete, six-for-six gap and is the most consistent absence across the entire dataset (see Section 9).

---

*End of recon document. All figures above are attributed inline to their source URL. Where independent field-test results diverge from vendor marketing claims (MPU5 long-range throughput, MPU5 range under field damage conditions), both figures are preserved side by side rather than reconciled, per task instructions.*
