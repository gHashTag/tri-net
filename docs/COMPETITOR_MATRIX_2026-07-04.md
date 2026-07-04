# Competitor Matrix — MANET / Drone-Mesh Radios (2026-07-04)

**Anchor**: φ² + φ⁻² = 3
**Scope**: 10 competitor radios; every value below is bound to a URL fetched during 2026-07-04 research session (see `docs/WAVE_REPORT_COMPETITORS_2026-07-03.md` for strategic framing).
**Auditability discipline**: values marked `n.a.` were not confirmed from a fetched source; `quote only` = vendor does not publish list price on any page checked. No numbers were filled from memory or training data.
**Tri-Net position**: Not benchmarked in this matrix — see `docs/BENCHMARK_VS_MANET_2026-07-04.md` for our column and `docs/WAVE_N3_AUDITABILITY_GAP_2026-07-04.md` for the vendor-field discrepancy metric `D = V/F`.

---

## Sweep table — throughput, TX power, weight, price

Columns compressed for cross-vendor comparison. See per-entity sections below for the full 15 fields.

| # | Vendor / Product | Country | Peak Mbps (vendor) | Field Mbps (indep.) | TX power | Weight (module) | Waveform | FIPS | Unit price (USD) |
|---|---|---|---|---|---|---|---|---|---|
| 1 | [Persistent MPU5 (Wave Relay)](https://www.persistentsystems.com/mpu5/) | USA | [150](https://persistentsystems.com/mpu5-specs/) | [~150 peak / ~100 aggregate](https://triadrf.com/resources/persistent-mpu5-data-link-testing.pdf) | [6–10 W (33 dBm)](https://persistentsystems.com/mpu5-specs/) | [~391 g](https://persistentsystems.com/radio-modules-dev/) | Wave Relay 3×3 MIMO | [140-2 L2 #3183](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/3183) | [~$18k (USAF)](https://persistentsystems.com/persistent-systems-awarded-5-1-million-contract-to-supply-mpu5-radios-to-usaf/) |
| 2 | [Rajant Kinetic Mesh (BreadCrumb DX2/ES1/LX5/ME4)](https://rajant.com/products/) | USA | [300 PHY](https://rajant.com/wp-content/uploads/2023/11/Rajant_BreadCrumb-Brochure_110223.pdf) | n.a. | [30 dBm @2.4](https://rajant.com/wp-content/uploads/2023/11/Rajant_BreadCrumb-Brochure_110223.pdf) | [123–1850 g](https://rajant.com/wp-content/uploads/2023/11/Rajant_BreadCrumb-Brochure_110223.pdf) | InstaMesh | [140-3 L2 RiSM (2025)](https://rajant.com/blog/rajants-rism-achieves-fips-140-3-level-2-certification-for-secure-network-mobility/) | [quote only](https://rajant.com/products/) |
| 3 | [Silvus StreamCaster (SC4200/SC4400)](https://silvustechnologies.com/products/streamcaster-radios/) | USA | [100](https://silvustechnologies.com/wp-content/uploads/2025/09/StreamCaster-4400-SC4400E-Enhanced-Datasheet.pdf) | [10 Mbps @ 75 km](https://silvustechnologies.com/wp-content/uploads/2025/09/Silvus_Loitering-Munitions-Brochure.pdf) | [10–20 W](https://silvustechnologies.com/wp-content/uploads/2022/09/StreamCaster-4200-SC4200-Plus-Drop-In-Module-Datasheet.pdf) | [52–288 g](https://silvustechnologies.com/wp-content/uploads/2022/09/StreamCaster-4200-SC4200-Plus-Drop-In-Module-Datasheet.pdf) | MN-MIMO | [140-3 L2 (first MANET)](https://www.prnewswire.com/news-releases/silvus-streamcaster-4400-becomes-first-mobile-ad-hoc-network-manet-radio-to-achieve-fips-140-3-level-2-validation-302357200.html) | [quote only](https://silvustechnologies.com/products/streamcaster-radios/) |
| 4 | [TrellisWare TSM (TW-950/875/750)](https://www.trellisware.com/products/) | USA | [50+ single-hop](https://www.trellisware.com/wp-content/uploads/2023/09/TSM-Waveform-Datasheet.pdf) | n.a. | [0.1–20 W](https://www.unmannedsystemstechnology.com/wp-content/uploads/2022/11/TrellisWare-Product-Catalog-August-2022-1.pdf) | [320–450 g](https://www.trellisware.com/wp-content/uploads/2023/01/TW-875-Datasheet_Letter_2023_Interactive.pdf) | TSM/Barrage Relay | [140-2 #4155](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4155) | [quote only](https://www.trellisware.com/products/) |
| 5 | [Doodle Labs Mesh Rider](https://doodlelabs.com/products/) | USA/SG | [80–100](https://5.imimg.com/data5/SELLER/Doc/2025/7/523965238/GK/ST/PG/14158318/doodle-labs-oem-mesh-rider-radio.pdf) | [>100 km field (vendor)](https://doodlelabs.com/product/oem/) | [2 W (33 dBm)](https://5.imimg.com/data5/SELLER/Doc/2025/7/523965238/GK/ST/PG/14158318/doodle-labs-oem-mesh-rider-radio.pdf) | [25–102 g](https://doodlelabs.com/product/oem/) | Mesh Rider OFDM/MIMO | [140-3 claimed](https://doodlelabs.com/product/oem/) | [~$1,500/radio](https://www.reddit.com/r/ATAK/comments/1g1loee/) |
| 6 | [goTenna Pro X2 / X2m](https://gotennapro.com/products/gotenna-pro-x2) | USA | kbit/s tier | n.a. | [0.5–5 W](https://gotennapro.com/products/gotenna-pro-x2) | [100–182 g](https://gotenna.com/products/gotenna-pro-x2m) | Aspen Grove 4GFSK | n.a. | [~$1,200 (Texas ANG)](https://www.airandspaceforces.com/texas-air-national-guard-tacp-gotenna/) |
| 7 | [Microhard pMDDL / pDDL 2450](https://www.microhardcorp.com/pMDDL2450.php) | CAN | [~25–28](https://www.microhardcorp.com/pMDDL2450.php) | [~10 Mbps @ 4 km LOS](https://forum.modalai.com/topic/1938/) | [1 W (30 dBm)](https://www.microhardcorp.com/brochures/pDDL2450.Brochure.Rev.1.4.1.pdf) | [5–165 g](https://www.microhardcorp.com/pMDDL2450.php) | COFDM 2×2 MIMO | n.a. | [~$238–760](https://www.accio.com/plp/microhard-pmddl2450-datasheet) |
| 8 | [Mobilicom SkyHopper / MCU-30](https://mobilicom.com/) | IL/AU | [1–20](https://mobilicom.com/wp-content/uploads/2024/08/SKH-PRO-Lite-Micro-08082024.pdf) | n.a. | [1–2 W](https://mobilicom.com/wp-content/uploads/2024/08/SKH-PRO-Lite-Micro-08082024.pdf) | [62–550 g](https://mobilicom.com/wp-content/uploads/2024/08/SKH-PRO-Lite-Micro-08082024.pdf) | 4G Mobile MESH OFDM/TDD | n.a. | [quote only](https://mobilicom.com/) |
| 9 | [Elistair Khronos (Silvus SC4200P inside)](https://elistair.com/solutions/tethered-dronebox-khronos/) | FR | [100 tethered](https://elistair.com/solutions/tethered-dronebox-khronos/) | via Silvus | inherited Silvus | ~30.8 kg platform | Silvus MN-MIMO | via Silvus 140-3 L2 | [~$22k–140k platform](https://elistair.com/resources/general-information-about-tethered-drones/tethered-drone-systems-vs-traditional-drones-what-is-the-difference/) |
| 10 | [Fraunhofer IIS mioty (TS-UNB)](https://www.iis.fraunhofer.de/en/ff/lv/net/telemetrie.html) | DE | [407 bit/s](https://www.iis.fraunhofer.de/content/dam/iis/de/doc/lv/ok/20180504-MIOTY-Flyer-DIN-lang-8S-en-WEB.pdf) | [~512 bit/s](https://pages.silabs.com/rs/634-SLU-379/images/Mioty-Whitepaper-Silicon-Labs.pdf?version=0) | [14 dBm ERP](https://www.farnell.com/datasheets/3779428.pdf) | [~90 g PCBA](https://www.farnell.com/datasheets/3779428.pdf) | ETSI TS 103 357 | n.a. | quote only (licensed stack) |

---

## Segment map

**Segment A — High-throughput tactical MANET (100+ Mbps class, defense PoR):**
Persistent MPU5, Rajant Kinetic Mesh, Silvus StreamCaster, TrellisWare TSM. All USA. Waveforms proprietary. FIPS-certified crypto modules. Prices in the $18k–$50k range where discoverable (MPU5 GSA line: [$405,615 / 8 systems ≈ $50k/system](https://www.highergov.com/contract/FA524023P0092/)). This is where MPU5's vendor-vs-field gap (`D = 16..60`, see δ paper) lives.

**Segment B — Drone datalinks, low-SWaP, Blue UAS / NDAA:**
Doodle Labs Mesh Rider, Microhard pMDDL/pDDL, Mobilicom SkyHopper, Elistair Khronos (Silvus inside). Optimized 25–500 g modules, 10–100 Mbps, 1–2 W TX. Public prices only for Doodle Labs and Microhard. Weight advantage on Helix (~25 g).

**Segment C — Low-bandwidth PLI/telemetry (kbit/s tier):**
goTenna Pro X2 (Aspen Grove) and Fraunhofer mioty (TS-UNB). Not competitors for video/mesh throughput but adjacent for command-and-control fallback. mioty is the only open ETSI spec in the entire set — the closest to our aspiration of spec-openness.

---

## Detailed per-entity sections

### 1. Persistent Systems MPU5

| Field | Value |
|---|---|
| Vendor & product | [Persistent Systems — MPU5 (Wave Relay MANET radio)](https://www.persistentsystems.com/mpu5/) |
| Country | [USA (New York, NY)](https://www.persistentsystems.com/mpu5/) |
| Frequency bands | [L 1350–1390, S 2200–2507, BAS 2025–2150, C 4400–5000 & 5100–6000 MHz](https://persistentsystems.com/mpu5-specs/) |
| Peak throughput (vendor) | [Up to 150 Mbps @ 20 MHz (120 Mbps on C-band)](https://persistentsystems.com/mpu5-specs/) |
| Independent / field | [~150 Mbps peak TCP @ 20 MHz (Boston Dynamics testing)](https://bostondynamics.com/wp-content/uploads/2023/05/persistent-systems-radio-kit.pdf); [~100 Mbps aggregate / ~33 Mbps per channel (TriadRF)](https://triadrf.com/resources/persistent-mpu5-data-link-testing.pdf) |
| TX power | [6–10 W (up to 33 dBm; 2 W per chain)](https://persistentsystems.com/mpu5-specs/) |
| Range (vendor) | [Up to 130 miles between nodes](https://persistentsystems.com/mpu5-specs/) |
| Weight (module) | [Chassis ~391 g; ~130 g per RF module](https://persistentsystems.com/radio-modules-dev/) |
| Power (RX + TX) | [RX ~1.9 W; TX peak ~40 W](https://persistentsystems.com/mpu5-specs/) |
| Waveform | [Wave Relay MANET, 3×3 MIMO](https://persistentsystems.com/mpu5-specs/) |
| Crypto / cert | [CTR-AES-256, HMAC-SHA-256, CNSA/Suite-B; FIPS 140-2 L2 (module certs #3183, #3234)](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/3183) |
| Spec openness | [Proprietary Wave Relay waveform; datasheet published, protocol closed](https://persistentsystems.com/mpu5-specs/) |
| SDK / API | [Developer API + Android app support](https://persistentsystems.com/mpu5-specs/) |
| Unit price | [~$18k implied by USAF $5.1M / 280 radios](https://persistentsystems.com/persistent-systems-awarded-5-1-million-contract-to-supply-mpu5-radios-to-usaf/); [$50k/system on GSA contract of 8](https://www.highergov.com/contract/FA524023P0092/) |
| Notable deployments | [USAF Air Mobility Command](https://persistentsystems.com/persistent-systems-awarded-5-1-million-contract-to-supply-mpu5-radios-to-usaf/); [Boston Dynamics robot kit](https://bostondynamics.com/wp-content/uploads/2023/05/persistent-systems-radio-kit.pdf) |

**Note**: Aerobavovna field report (2.5–9.3 Mbps) and US Army Rakkasan range-collapse referenced in `WAVE_N3_AUDITABILITY_GAP_2026-07-04.md` — those are the operator-side data feeding `D = V/F`.

### 2. Rajant Kinetic Mesh (BreadCrumb DX2/ES1/LX5/ME4)

| Field | Value |
|---|---|
| Vendor & product | [Rajant — Kinetic Mesh BreadCrumb](https://rajant.com/products/) |
| Country | [USA (Malvern, PA)](https://rajant.com/products/) |
| Frequency bands | [DX2/ES1: 2.4/5 GHz; LX5: 900 MHz/2.4/5; ME4: 2.4/4.9/5](https://rajant.com/wp-content/uploads/2023/11/Rajant_BreadCrumb-Brochure_110223.pdf) |
| Peak throughput | [Up to 300 Mbps PHY (DX2/ES1)](https://rajant.com/wp-content/uploads/2023/11/Rajant_BreadCrumb-Brochure_110223.pdf) |
| Independent / field | [n.a. — brochure checked; no third-party field test found](https://rajant.com/wp-content/uploads/2023/11/Rajant_BreadCrumb-Brochure_110223.pdf) |
| TX power | [DX2: 30 dBm @2.4 / 27 dBm @5; ES1: 29 dBm](https://rajant.com/wp-content/uploads/2023/11/Rajant_BreadCrumb-Brochure_110223.pdf) |
| Range (vendor) | [n.a. — no single-hop range figure on brochure](https://rajant.com/wp-content/uploads/2023/11/Rajant_BreadCrumb-Brochure_110223.pdf) |
| Weight | [DX2 ~123 g magnesium; ES1 ~455 g; LX5 ~1850 g; ME4 ~1074–1312 g](https://rajant.com/wp-content/uploads/2023/11/Rajant_BreadCrumb-Brochure_110223.pdf) |
| Power (RX + TX) | [DX2: 2.8 W / 7.5 W; ES1: 2.8 W / 15 W; LX5: 7–8 W / 26–33 W](https://rajant.com/wp-content/uploads/2023/11/Rajant_BreadCrumb-Brochure_110223.pdf) |
| Waveform | [InstaMesh (make-make-break routing)](https://rajant.com/wp-content/uploads/2023/11/Rajant_BreadCrumb-Brochure_110223.pdf) |
| Crypto / cert | [AES-256 GCM/CTR + XSalsa20; RiSM FIPS 140-3 L2 (Dec 2025); legacy ME4 FIPS 140-2 L2 #2740](https://rajant.com/blog/rajants-rism-achieves-fips-140-3-level-2-certification-for-secure-network-mobility/) |
| Spec openness | [Proprietary InstaMesh; brochure detailed, protocol closed](https://rajant.com/wp-content/uploads/2023/11/Rajant_BreadCrumb-Brochure_110223.pdf) |
| SDK / API | [BC\|Commander management tool; no public developer SDK on page checked](https://rajant.com/products/) |
| Unit price | [Quote only — no public price on vendor page](https://rajant.com/products/) |
| Notable deployments | [Mining, military, industrial mobile networks](https://rajant.com/products/) |

### 3. Silvus StreamCaster (SC4200 / SC4400)

| Field | Value |
|---|---|
| Vendor & product | [Silvus Technologies — StreamCaster radios](https://silvustechnologies.com/products/streamcaster-radios/) |
| Country | [USA (Los Angeles, CA)](https://silvustechnologies.com/products/streamcaster-radios/) |
| Frequency bands | [300 MHz – 6 GHz tunable](https://silvustechnologies.com/wp-content/uploads/2025/09/StreamCaster-4400-SC4400E-Enhanced-Datasheet.pdf) |
| Peak throughput | [Up to 100 Mbps](https://silvustechnologies.com/wp-content/uploads/2025/09/StreamCaster-4400-SC4400E-Enhanced-Datasheet.pdf) |
| Independent / field | [75 km link @ 10 Mbps (loitering-munitions brochure)](https://silvustechnologies.com/wp-content/uploads/2025/09/Silvus_Loitering-Munitions-Brochure.pdf) |
| TX power | [SC4400 up to 20 W (80 W effective w/ MIMO); SC4200Plus up to 10 W](https://silvustechnologies.com/wp-content/uploads/2022/09/StreamCaster-4200-SC4200-Plus-Drop-In-Module-Datasheet.pdf) |
| Range (vendor) | [75 km demonstrated at reduced rate](https://silvustechnologies.com/wp-content/uploads/2025/09/Silvus_Loitering-Munitions-Brochure.pdf) |
| Weight | [SC4200 OEM ~137 g; SC4400 OEM ~288 g; SL5200 OEM ~52 g](https://silvustechnologies.com/wp-content/uploads/2022/09/StreamCaster-4200-SC4200-Plus-Drop-In-Module-Datasheet.pdf) |
| Power (RX + TX) | [SC4200 ~5–48 W; SC4400 ~8–100 W](https://silvustechnologies.com/wp-content/uploads/2025/09/StreamCaster-4400-SC4400E-Enhanced-Datasheet.pdf) |
| Waveform | [MN-MIMO (Mobile Networked MIMO)](https://silvustechnologies.com/wp-content/uploads/2025/09/StreamCaster-4400-SC4400E-Enhanced-Datasheet.pdf) |
| Crypto / cert | [AES-256; first MANET FIPS 140-3 L2 (Jan 2025)](https://www.prnewswire.com/news-releases/silvus-streamcaster-4400-becomes-first-mobile-ad-hoc-network-manet-radio-to-achieve-fips-140-3-level-2-validation-302357200.html) |
| Spec openness | [Proprietary MN-MIMO; datasheets published, protocol closed](https://silvustechnologies.com/wp-content/uploads/2025/09/StreamCaster-4400-SC4400E-Enhanced-Datasheet.pdf) |
| SDK / API | [StreamScape management + ATAK plugin](https://silvustechnologies.com/products/streamcaster-radios/) |
| Unit price | [Quote only](https://silvustechnologies.com/products/streamcaster-radios/) |
| Notable deployments | [Elistair Khronos tethered UAS radio](https://silvustechnologies.com/wp-content/uploads/2025/09/Silvus_Loitering-Munitions-Brochure.pdf) |

### 4. TrellisWare TSM

| Field | Value |
|---|---|
| Vendor & product | [TrellisWare — TSM family (TW-950/875/750)](https://www.trellisware.com/products/) |
| Country | [USA (San Diego, CA)](https://www.trellisware.com/products/) |
| Frequency bands | [L-UHF 225–450, U-UHF 698–970, L/S 1250–2600 MHz](https://www.trellisware.com/wp-content/uploads/2023/09/TSM-Waveform-Datasheet.pdf) |
| Peak throughput | [50+ Mbps single-hop; 32 Mbps 1-hop TW-950 (TSM6)](https://www.trellisware.com/wp-content/uploads/2023/09/TSM-Waveform-Datasheet.pdf) |
| Independent / field | [n.a. — no third-party test located](https://www.trellisware.com/wp-content/uploads/2023/09/TSM-Waveform-Datasheet.pdf) |
| TX power | [TW-950: 100 mW–2 W; TW-750: up to 20 W](https://www.unmannedsystemstechnology.com/wp-content/uploads/2022/11/TrellisWare-Product-Catalog-August-2022-1.pdf) |
| Range (vendor) | [26 mi/hop; up to 205 mi/hop Long Range Mode](https://www.trellisware.com/wp-content/uploads/2023/09/TSM-Waveform-Datasheet.pdf) |
| Weight | [TW-950 ~320 g; TW-875 ~450 g](https://www.trellisware.com/wp-content/uploads/2023/01/TW-875-Datasheet_Letter_2023_Interactive.pdf) |
| Power (RX + TX) | [n.a. — catalog gives TX power, not Watt split](https://www.unmannedsystemstechnology.com/wp-content/uploads/2022/11/TrellisWare-Product-Catalog-August-2022-1.pdf) |
| Waveform | [TSM (Barrage Relay) and Katana](https://www.trellisware.com/wp-content/uploads/2023/09/TSM-Waveform-Datasheet.pdf) |
| Crypto / cert | [AES-256 commercial; WREN TSM adds NSA Type-1; FIPS 140-2 #4155](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4155) |
| Spec openness | [Proprietary TSM/Barrage Relay; datasheets published, protocol closed](https://www.trellisware.com/wp-content/uploads/2023/09/TSM-Waveform-Datasheet.pdf) |
| SDK / API | [APIs for 3rd-party integration](https://www.unmannedsystemstechnology.com/wp-content/uploads/2022/11/TrellisWare-Product-Catalog-August-2022-1.pdf) |
| Unit price | [Quote only](https://www.trellisware.com/products/) |
| Notable deployments | [200,000+ TSM radios fielded globally (US Army/USMC/USSOCOM PoR)](https://www.trellisware.com/trellisware-achieves-global-deployment-of-200000-tsm-enabled-radios/) |

### 5. Doodle Labs Mesh Rider

| Field | Value |
|---|---|
| Vendor & product | [Doodle Labs — Mesh Rider (OEM/Mini/Nano/Helix/Wearable)](https://doodlelabs.com/products/) |
| Country | [USA/Singapore; markets to DoD Blue UAS](https://doodlelabs.com/product/oem/) |
| Frequency bands | [255 MHz – 5925 MHz across family (Helix M1–M6 = 1.6–2.5 GHz + L/S/C)](https://doodlelabs.com/product/oem/) |
| Peak throughput | [80–100 Mbps (20–40 MHz channels)](https://5.imimg.com/data5/SELLER/Doc/2025/7/523965238/GK/ST/PG/14158318/doodle-labs-oem-mesh-rider-radio.pdf) |
| Independent / field | [Field-tested >100 km; 80 km fixed-wing link in Ukraine w/ 8 HD video streams (vendor-reported)](https://doodlelabs.com/product/oem/) |
| TX power | [Up to 2 W (33 dBm)](https://5.imimg.com/data5/SELLER/Doc/2025/7/523965238/GK/ST/PG/14158318/doodle-labs-oem-mesh-rider-radio.pdf) |
| Range (vendor) | [>100 km field-tested](https://doodlelabs.com/product/oem/) |
| Weight | [Helix OEM ~25 g; Nano ~34 g; Mini ~36.5 g; standard OEM ~102 g](https://doodlelabs.com/product/oem/) |
| Power (RX + TX) | [~14 W peak TX; ~2–3.5 W RX](https://5.imimg.com/data5/SELLER/Doc/2025/7/523965238/GK/ST/PG/14158318/doodle-labs-oem-mesh-rider-radio.pdf) |
| Waveform | [Mesh Rider (patented OFDM/MIMO with LPI/LPD)](https://doodlelabs.com/product/oem/) |
| Crypto / cert | [AES-256/128 software-selectable; FIPS 140-3 compliant (vendor claim)](https://doodlelabs.com/product/oem/) |
| Spec openness | [Proprietary waveform; runs open Mesh Rider OS (OpenWrt-based)](https://doodlelabs.com/product/oem/) |
| SDK / API | [Mesh Rider OS with developer access](https://doodlelabs.com/product/oem/) |
| Unit price | [~$1,500/radio, ~$2,000–2,600 per kit (community reports)](https://www.reddit.com/r/ATAK/comments/1g1loee/) |
| Notable deployments | [DIU/DoD Blue UAS; Ukraine fixed-wing UAS (vendor-reported)](https://doodlelabs.com/product/oem/) |

### 6. goTenna Pro X2 / X2m

| Field | Value |
|---|---|
| Vendor & product | [goTenna — Pro X2 tactical mesh](https://gotennapro.com/products/gotenna-pro-x2) |
| Country | [USA (Brooklyn, NY)](https://gotennapro.com/products/gotenna-pro-x2) |
| Frequency bands | [VHF 142–175 / UHF 445–480 MHz; 6.25/12.5/25 kHz channel BW](https://gotennapro.com/products/gotenna-pro-x2) |
| Peak throughput | [Short-burst PLI/text over <25 kHz — n.a. as Mbps](https://gotenna.com/pages/aspen-grove) |
| Independent / field | [n.a. — low-bandwidth mesh](https://gotenna.com/pages/aspen-grove) |
| TX power | [0.5 / 1 / 2 / 5 W (27–37 dBm)](https://gotennapro.com/products/gotenna-pro-x2) |
| Range (vendor) | [15 mi body / 55 mi ground relay / 100+ mi aerial relay](https://gotennapro.com/products/gotenna-pro-x2) |
| Weight | [Pro X2 ~100 g; X2m ~182.5 g](https://gotenna.com/products/gotenna-pro-x2m) |
| Power (RX + TX) | [n.a. — battery life quoted, not Watts](https://gotennapro.com/products/gotenna-pro-x2) |
| Waveform | [Aspen Grove mesh (4GFSK, proprietary)](https://gotenna.com/pages/aspen-grove) |
| Crypto / cert | [AES-256 via ATAK; 384-bit ECDH/ECC PKI; FIPS cert n.a. on page](https://gotennapro.com/products/gotenna-pro-x2) |
| Spec openness | [Proprietary Aspen Grove](https://gotenna.com/pages/aspen-grove) |
| SDK / API | [Partners & integrations program](https://gotennapro.com/pages/partners-and-integrations) |
| Unit price | [~$1,200/unit (Texas ANG TACP)](https://www.airandspaceforces.com/texas-air-national-guard-tacp-gotenna/) |
| Notable deployments | [USAF TACP Texas Air National Guard](https://www.airandspaceforces.com/texas-air-national-guard-tacp-gotenna/) |

### 7. Microhard pMDDL / pDDL 2450

| Field | Value |
|---|---|
| Vendor & product | [Microhard — pMDDL2450 / pDDL2450](https://www.microhardcorp.com/pMDDL2450.php) |
| Country | [Canada (Calgary)](https://www.modalai.com/products/oem-m0048-4-1) |
| Frequency bands | [2.402–2.478 GHz (2450 variant); family: 900 MHz, 2.3, 2.5, 5.8 GHz](https://www.microhardcorp.com/brochures/pDDL2450.Brochure.Rev.1.4.1.pdf) |
| Peak throughput | [~25–28 Mbps @ 8 MHz](https://www.microhardcorp.com/pMDDL2450.php) |
| Independent / field | [~10 Mbps @ 4 km LOS (ModalAI developer forum)](https://forum.modalai.com/topic/1938/) |
| TX power | [1 W (30 dBm)](https://www.microhardcorp.com/brochures/pDDL2450.Brochure.Rev.1.4.1.pdf) |
| Range (vendor) | [n.a. — brochure emphasizes range but no single figure](https://www.microhardcorp.com/brochures/pDDL2450.Brochure.Rev.1.4.1.pdf) |
| Weight | [OEM ~5–7 g; motherboard ~55 g; enclosed ~165 g](https://www.microhardcorp.com/pMDDL2450.php) |
| Power (RX + TX) | [n.a. — Watt split not stated](https://www.microhardcorp.com/pMDDL2450.php) |
| Waveform | [COFDM 2×2 MIMO (MRC/ML/LDPC); PTP/PMP/Mesh](https://www.microhardcorp.com/brochures/pDDL2450.Brochure.Rev.1.4.1.pdf) |
| Crypto / cert | [AES-128 standard; AES-256 optional (export-permit); NDAA-compliant; no FIPS cert on page](https://www.microhardcorp.com/brochures/pDDL2450.Brochure.Rev.1.4.1.pdf) |
| Spec openness | [Proprietary; CLI/telnet/web-UI config](https://www.microhardcorp.com/pMDDL2450.php) |
| SDK / API | [CLI/web-UI/telnet; no formal SDK on page](https://www.microhardcorp.com/pMDDL2450.php) |
| Unit price | [pMDDL2450-ENC ~$559–760; pDDL2450-OEM ~$238 (reseller listings)](https://www.accio.com/plp/microhard-pmddl2450-datasheet) |
| Notable deployments | [ModalAI VOXL autonomy platform](https://www.modalai.com/products/oem-m0048-4-1) |

### 8. Mobilicom SkyHopper PRO / MCU-30

| Field | Value |
|---|---|
| Vendor & product | [Mobilicom — SkyHopper PRO / MCU-30](https://mobilicom.com/) |
| Country | [Israel (with Australia listing)](https://mobilicom.com/) |
| Frequency bands | [SkyHopper PRO: 2.3–2.7 / 4.9–5.9 GHz; MCU-30: 75 MHz–6 GHz](https://mobilicom.com/wp-content/uploads/2024/08/SKH-PRO-Lite-Micro-08082024.pdf) |
| Peak throughput | [SkyHopper PRO: 0.95–6.4 Mbps; MCU-30: 1.6–10 Mbps (up to 20)](https://mobilicom.com/wp-content/uploads/2024/08/SKH-PRO-Lite-Micro-08082024.pdf) |
| Independent / field | [n.a.](https://mobilicom.com/wp-content/uploads/2024/08/SKH-PRO-Lite-Micro-08082024.pdf) |
| TX power | [SkyHopper PRO: 1 W peak/antenna, 0.2 W avg (23 dBm); MCU-30: up to 2 W total](https://mobilicom.com/wp-content/uploads/2024/08/SKH-PRO-Lite-Micro-08082024.pdf) |
| Range (vendor) | [SkyHopper PRO: 5 km LOS/hop; MCU-30: 15 km omni / 20–30 km directional](https://mobilicom.com/wp-content/uploads/2022/06/MCU30-Extended-Ruggedized-2020.pdf) |
| Weight | [SkyHopper PRO 119 g / Lite 99 g / Micro 62 g; MCU-30 ~550 g](https://mobilicom.com/wp-content/uploads/2024/08/SKH-PRO-Lite-Micro-08082024.pdf) |
| Power (RX + TX) | [SkyHopper PRO: 13 W peak, ~12 W avg; MCU-30: 8–12 W](https://mobilicom.com/wp-content/uploads/2024/08/SKH-PRO-Lite-Micro-08082024.pdf) |
| Waveform | [Proprietary SDR "4G Mobile MESH", OFDM/TDD, 2×2 MIMO](https://mobilicom.com/wp-content/uploads/2024/08/SKH-PRO-Lite-Micro-08082024.pdf) |
| Crypto / cert | [AES-128 standard; AES-256 optional; ICE cyber suite; no FIPS on page](https://mobilicom.com/wp-content/uploads/2024/08/SKH-PRO-Lite-Micro-08082024.pdf) |
| Spec openness | [Proprietary; NDAA/Blue UAS](https://mobilicom.com/wp-content/uploads/2024/08/SKH-PRO-Lite-Micro-08082024.pdf) |
| SDK / API | [IP-based / web-GUI (via ArkElectron integration guide)](https://docs.arkelectron.com/radio-integration/mobilicom-skyhopper-pro-lite-radio-integration) |
| Unit price | [Quote only](https://mobilicom.com/) |
| Notable deployments | [Israeli defense including IAI integration](https://mobilicom.com/) |

### 9. Elistair Khronos

| Field | Value |
|---|---|
| Vendor & product | [Elistair — Khronos tethered drone-in-a-box (Silvus SC4200P inside)](https://elistair.com/solutions/tethered-dronebox-khronos/) |
| Country | [France (Lyon)](https://elistair.com/solutions/tethered-dronebox-khronos/) |
| Frequency bands | [Inherited from Silvus SC4200P: 300 MHz – 6 GHz; tether carries data optically](https://elistair.com/solutions/tethered-dronebox-khronos/) |
| Peak throughput | [100 Mb/s over the 70 m micro-tether](https://elistair.com/solutions/tethered-dronebox-khronos/) |
| Independent / field | [n.a. — radio field data under Silvus entry](https://elistair.com/solutions/tethered-dronebox-khronos/) |
| TX power | [Inherited from Silvus SC4200P (up to 10 W); tether wired](https://elistair.com/solutions/tethered-dronebox-khronos/) |
| Range (vendor) | [24 h endurance, 60 m tether altitude, up to 10 km ISR radius](https://elistair.com/solutions/tethered-dronebox-khronos/) |
| Weight | [~30.8 kg (platform, not module)](https://elistair.com/solutions/tethered-dronebox-khronos/) |
| Power (RX + TX) | [n.a. — mains/tether-powered](https://elistair.com/solutions/tethered-dronebox-khronos/) |
| Waveform | [Silvus MN-MIMO via integrated StreamCaster](https://elistair.com/solutions/tethered-dronebox-khronos/) |
| Crypto / cert | [AES-256 / FIPS 140-3 L2 inherited from Silvus](https://www.prnewswire.com/news-releases/silvus-streamcaster-4400-becomes-first-mobile-ad-hoc-network-manet-radio-to-achieve-fips-140-3-level-2-validation-302357200.html) |
| Spec openness | [ITAR-free, NDAA-compliant; underlying radio proprietary](https://elistair.com/solutions/tethered-dronebox-khronos/) |
| SDK / API | [Platform integration; radio API via Silvus StreamScape](https://elistair.com/solutions/tethered-dronebox-khronos/) |
| Unit price | [Quote only; tethered systems generally €20k–€130k (~$22k–$140k)](https://elistair.com/resources/general-information-about-tethered-drones/tethered-drone-systems-vs-traditional-drones-what-is-the-difference/) |
| Notable deployments | [Dual-payload configuration; Silvus + Elistair since 2019 (ORION)](https://elistair.com/company-news/product-releases/elistair-unveils-khronos-dual-payload/) |

### 10. Fraunhofer IIS mioty (TS-UNB)

| Field | Value |
|---|---|
| Vendor & product | [Fraunhofer IIS — mioty® LPWAN protocol (TS-UNB)](https://www.iis.fraunhofer.de/en/ff/lv/net/telemetrie.html) |
| Country | [Germany (Erlangen/Nuremberg)](https://www.iis.fraunhofer.de/en/ff/lv/net/telemetrie.html) |
| Frequency bands | [915 MHz North America, 868 MHz Europe (sub-GHz license-free)](https://www.iis.fraunhofer.de/content/dam/iis/de/doc/lv/ok/20180504-MIOTY-Flyer-DIN-lang-8S-en-WEB.pdf) |
| Peak throughput | [407 bit/s per Fraunhofer flyer](https://www.iis.fraunhofer.de/content/dam/iis/de/doc/lv/ok/20180504-MIOTY-Flyer-DIN-lang-8S-en-WEB.pdf) |
| Independent / field | [~512 bit/s (Silicon Labs whitepaper)](https://pages.silabs.com/rs/634-SLU-379/images/Mioty-Whitepaper-Silicon-Labs.pdf?version=0) |
| TX power | [n.a. on flyer; front-end reference design supports 14 dBm (25 mW) ERP](https://www.farnell.com/datasheets/3779428.pdf) |
| Range (vendor) | [5 km dense urban, 15 km rural](https://www.iis.fraunhofer.de/content/dam/iis/de/doc/lv/ok/20180504-MIOTY-Flyer-DIN-lang-8S-en-WEB.pdf) |
| Weight | [Software protocol; SDR front-end PCBA ~90 g](https://www.farnell.com/datasheets/3779428.pdf) |
| Power (RX + TX) | [Ultra-low; ~35 mWs/message endpoint](https://www.iis.fraunhofer.de/content/dam/iis/de/doc/lv/ok/20180504-MIOTY-Flyer-DIN-lang-8S-en-WEB.pdf) |
| Waveform | [Telegram Splitting Ultra Narrow Band (TS-UNB), MSK; ETSI TS 103 357](https://pages.silabs.com/rs/634-SLU-379/images/Mioty-Whitepaper-Silicon-Labs.pdf?version=0) |
| Crypto / cert | [Multi-layer security cited; no FIPS cert on flyer](https://www.iis.fraunhofer.de/content/dam/iis/de/doc/lv/ok/20180504-MIOTY-Flyer-DIN-lang-8S-en-WEB.pdf) |
| Spec openness | [Open ETSI standard TS 103 357, vendor-independent — most open in set](https://pages.silabs.com/rs/634-SLU-379/images/Mioty-Whitepaper-Silicon-Labs.pdf?version=0) |
| SDK / API | [mioty IoT Node API and mioty IoT Hub API](https://www.iis.fraunhofer.de/content/dam/iis/de/doc/lv/ok/20180504-MIOTY-Flyer-DIN-lang-8S-en-WEB.pdf) |
| Unit price | [Quote only — licensed software stack, not priced unit](https://www.iis.fraunhofer.de/en/ff/lv/net/telemetrie.html) |
| Notable deployments | [Smart-city/industrial-IoT; GEO satellite (S-band) demonstration with EchoStar XXI](https://www.iis.fraunhofer.de/content/dam/iis/en/doc/pr/2021/20210722_en_mioty_geo_satellite.pdf) |

---

## Cross-competitor observations

- **Pricing opacity is universal.** Zero of 10 vendors publish list price on their own product page. Hard USD numbers come only from government contract records and community reports: MPU5 ~$18k–50k (USAF, GSA); goTenna ~$1,200 (Texas ANG); Doodle Labs ~$1,500 (community); Microhard $238–760 (resellers). Silvus, TrellisWare, Rajant, Mobilicom, Elistair — quote only. This opacity itself is a `D`-metric input: if `V` (price) is unpublished, procurement `F` (delivered value per dollar) cannot be independently audited.

- **Spec openness clusters at extremes.** Eight of ten are proprietary waveforms with published datasheets but closed protocols. The one true open outlier is [Fraunhofer mioty](https://pages.silabs.com/rs/634-SLU-379/images/Mioty-Whitepaper-Silicon-Labs.pdf?version=0) — a vendor-independent ETSI standard. Doodle Labs is partial: proprietary waveform but open Mesh Rider OS on OpenWrt.

- **Vendor-vs-field throughput gaps are almost never independently auditable.** Only Persistent MPU5 has genuine third-party corroboration ([Boston Dynamics](https://bostondynamics.com/wp-content/uploads/2023/05/persistent-systems-radio-kit.pdf) confirms ~150 Mbps; [TriadRF](https://triadrf.com/resources/persistent-mpu5-data-link-testing.pdf) shows ~100 Mbps aggregate). All other "field" numbers are vendor-reported (Doodle Labs Ukraine, Silvus 75 km, Mobilicom range). Rajant, TrellisWare, Mobilicom had zero third-party field data locatable in this session — an opacity worse than MPU5, because there is no operator counter-story to compute `D` against.

- **FIPS certification is a genuine hard differentiator.** [Silvus 140-3 L2](https://www.prnewswire.com/news-releases/silvus-streamcaster-4400-becomes-first-mobile-ad-hoc-network-manet-radio-to-achieve-fips-140-3-level-2-validation-302357200.html) and [Rajant RiSM 140-3 L2](https://rajant.com/blog/rajants-rism-achieves-fips-140-3-level-2-certification-for-secure-network-mobility/) are the current top tier. Persistent ([#3183](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/3183)) and TrellisWare ([#4155](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4155)) hold 140-2. Doodle Labs claims 140-3 "compliant" (not listed). Microhard, goTenna, Mobilicom, mioty — no verifiable FIPS cert on pages checked.

- **Country-of-origin drives procurement rules.** Six are USA (MPU5, Rajant, Silvus, TrellisWare, goTenna, Doodle Labs-marketed), one Canada (Microhard), one Israel (Mobilicom), one France (Elistair), one Germany (Fraunhofer). NDAA/Blue UAS compliance is loudly advertised specifically by the non-US-obvious drone vendors (Doodle Labs, Microhard, Mobilicom, Elistair).

- **SWaP scales predictably with throughput.** Lightest bare modules: Doodle Labs Helix (~25 g), Silvus SL5200 (~52 g), Mobilicom Micro (~62 g) — all airborne SWaP. Heaviest: Rajant LX5 (~1850 g), ME4 (~1074–1312 g) — fixed-infrastructure. TX power tracks same axis: mioty 14 dBm and goTenna 5 W low end; Silvus/TrellisWare 20 W high end.

- **Three market segments cleanly emerge**:
  - **Segment A (100+ Mbps, defense PoR)**: MPU5, Rajant, Silvus, TrellisWare. All US. FIPS-certified. $18–50k class.
  - **Segment B (Blue UAS drone datalinks)**: Doodle Labs, Microhard, Mobilicom, Elistair. 10–100 Mbps. Public price for Doodle/Microhard only.
  - **Segment C (PLI/telemetry, kbit/s)**: goTenna, mioty. Not throughput competitors but adjacent for C2 fallback / IoT.

## Data gaps (be transparent)

- RX+TX Watt splits: n.a. for TrellisWare, goTenna, Microhard on pages checked.
- Single-hop range: n.a. for Rajant, Microhard on pages checked.
- Independent field throughput: n.a. for Rajant, TrellisWare, Mobilicom.
- FIPS cert #: n.a. (or none) for Microhard, goTenna, Mobilicom, mioty.

These gaps are not estimated. Filling them is future recon work.

## Where Tri-Net stands (positioning, not comparison)

We do **not** occupy Segment A on throughput — that gate is closed by MIMO+PA+antenna capex we do not have. We do not compete for FIPS at 140-3 L2 today. **What we bring, uniquely, is spec openness with a reference implementation**:
- Bit-exact wire spec (`specs/wire.t27`) — public before the code.
- MIT-licensed daemon.
- Reproducible Yosys/nextpnr build (AX7203 IDCODE `0x13636093` proven on silicon; P201Mini M1 crypto on-device `hw` per [smoke/M1_RESULTS.md](https://github.com/gHashTag/tri-net/blob/main/smoke/M1_RESULTS.md)).
- BLAKE3 audit ring in the protocol itself.

This puts us adjacent to Fraunhofer mioty on the openness axis, but with throughput ambitions in Segment B. The δ paper ([WAVE_N3_AUDITABILITY_GAP](https://github.com/gHashTag/tri-net/blob/main/docs/WAVE_N3_AUDITABILITY_GAP_2026-07-04.md)) argues that openness is not an aesthetic — it is what makes `D = V/F` computable at all.

---

Anchor: φ² + φ⁻² = 3.
Compiled 2026-07-04 by cloud agent from wide-search subagent evidence base. Every value has a URL fetched in the research session. No values from memory or training.
