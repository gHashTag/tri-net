# Wave Report — Competitors x Trinity assets (2026-07-11)

Date: 2026-07-11
Wave: competitor / market-strategy pass (not a code audit)
Author: Dmitrii Vasilev - gHashTag
Anchor: phi^2 + phi^-2 = 3

This report maps the drone-mesh / tactical-mesh / wireless-DePIN field around
gHashTag/tri-net, compares eight players against Tri-Net, and maps each Trinity
artifact to the competitive moat it opens. It is a strategy deliverable. Every
external player carries a primary URL. No company, metric, or node-count is
invented.

---

## 0. Honesty preface (read first)

The whole point of Tri-Net is auditability, so the report audits itself before it
audits anyone else.

**Tri-Net current ground truth (verified against the repo at HEAD
`6850649`, 2026-07-07):**

- **`main` does not build.** `cargo build` on a clean checkout fails in
  `build.rs` (rustc `E0308` + `E0599`, lines 29-30). The mesh daemon cannot be
  produced from `main` right now. Any behavioural claim below that depends on the
  daemon is therefore paper-state, not runtime-state.
- **Control-plane (HELLO-beacon) auth is built but not wired.** The MAC +
  freshness primitive exists and is unit-tested in `src/discovery.rs`
  (`authenticated()`, `compute_mac()`, `verify_mac()`, `is_fresh()`). But the
  daemon sends beacons with `mac_key = None` (falls back to the hardcoded public
  constant `HELLO_MAC_KEY`, `src/bin/trios_meshd.rs:301`, marked `TODO: derive
  mac_key from session keys`), and the receive path
  (`trios_meshd.rs:182-186`) inserts every beacon into the neighbour table
  **without ever calling `verify_mac` or `is_fresh`**. Those two functions are
  invoked only from the test module. So on the wire today the control plane is
  effectively unauthenticated. This report does not claim otherwise.
- **Only AX7203 (Artix-7 `xc7a200t`) is proven-on-silicon.** The Zynq-7020 PL on
  the P201/P203 Mini has never been flashed with a Tri-Net bitstream; all PHY/RF
  numbers (OFDM, BPSK, 5.8 GHz) are `-sim` or digital-loopback only. The
  108.6 dB SNR figure is internal digital loopback, not over-the-air.
- **DePIN / tokenomics honesty.** No VC multipliers, no premine spin, no fabricated
  node counts. TRI supply schedule (`3^27`, 0% premine, 9 halvings) is contract
  source in `gHashTag/trinity-contracts`, **not deployed to mainnet**. Any
  per-operator yield is `[projected pre-Genesis]`. Chip-signed proof paths are
  `-sim` until the TT SKY26b tape-out (2026-12-16). The household-compute energy
  advantage is `x4-8` (95% CI `[3,10]`), never `x50-100`.
- **Silicon is submitted, not returned.** `tt-trinity` Phi / Euler / Gamma /
  Corona = 4 dies **submitted** to SKY26b; **silicon has not come back**. Every
  claim that depends on returned silicon is tagged `[Open conjecture]` with an
  explicit falsification path.

**How competitor numbers are tagged.** Vendor performance figures (TERASi
10 Gbps, Doodle Labs >100 km, etc.) are the vendor's own published claims, cited
to the vendor page and labelled as vendor-claimed. We do not independently
verify them; we do not launder them into facts.

---

## 1. Wave A — Segment map (four segments)

The field splits along one axis Tri-Net actually cares about: **how tightly the
value is bound to a specific piece of hardware**, and **how open the stack is**.
Four segments fall out.

### Segment 1 - Tethered comms (an anchor trades autonomy for endurance)

A drone or aerostat held by a cable; power and data run up the tether, so it
loiters for hours-to-days as a fixed relay.

| Player | Product | Primary URL |
|---|---|---|
| Elistair (FR) | Khronos tethered DroneBox - up to 24 h aloft at up to 60 m, operational in under 2 min; fielded at France's ORION 2026 exercise | [elistair.com](https://elistair.com/solutions/tethered-dronebox-khronos/), [UST ORION 2026](https://www.unmannedsystemstechnology.com/2026/05/elistairs-khronos-tethered-dronebox-supports-multi-domain-operations-orion-2026/) |
| AT&T Flying COW | Tethered 5G "Cell on Wings" - ~300-450 ft, ~10 sq mi coverage, ~5000 W / 450 V up the tether, days aloft | [commercialuavnews.com](https://www.commercialuavnews.com/public-safety/at-t-s-flying-cow-transmits-5g-network-by-tethered-drone) |
| Zenith Aerotech | Tethered Aerial Vehicles (TAVs) as persistent relay masts | [zenithaerotech.com](https://zenithaerotech.com) |

Strength: hours-to-days of stable loiter, a ready market (military, events,
disaster). Weakness: the tether is a leash - fixed radius, zero ad-hoc topology,
closed stack, no on-board inference.

### Segment 2 - mm-wave mesh (gigabits, but needs line-of-sight and thick silicon)

Above 60 GHz: very high throughput, very low latency, pencil beams, at the cost of
a proprietary mm-wave front-end and DSP.

| Player | Product | Primary URL |
|---|---|---|
| TERASi (SE, KTH spinout) | RU1 - >60 GHz pocket mm-wave radio, drone/tripod mount, self-forming mesh, "cannot be remotely switched off". Vendor-claimed up to 10 Gbps (future 20 Gbps) and <5 ms latency. | [thenextweb.com](https://thenextweb.com/news/swedish-starlink-alternative-ru1-military-communications), [edrmagazine.eu](https://www.edrmagazine.eu/swedish-spinout-terasi-launches-worlds-smallest-and-lightest-mm-wave-radio-for-mission-critical-operations-in-defence-disaster-relief-and-off-grid-industries) |

Strength: raw throughput and latency, sovereign (no external kill switch), VC and
defence interest. Weakness: closed DSP, expensive mm-wave front-end, no public
bit-exact contract - a vendor firmware patch changes network behaviour with no
third-party audit path.

### Segment 3 - MANET software stacks (mature ad-hoc mesh over commodity radio)

The crowded segment: proven self-forming/self-healing waveforms and routing, sold
as radios or SDKs.

| Player | Product | Primary URL |
|---|---|---|
| Persistent Systems | MPU5 / Wave Relay - 3x3 MIMO, 10 W, node entry <1 s, no hop limit, Android-based Wave Relay OS, waveform in an FPGA bitstream | [persistentsystems.com](https://persistentsystems.com/mpu5-specs/) |
| TrellisWare | TSM + Katana wideband waveforms - >225,000 systems fielded; UK MoD selection for >5,000 radios (Mar 2026) | [trellisware.com](https://www.trellisware.com/waveforms/tsm-waveform/), [UK MoD PR](https://www.prnewswire.com/news-releases/uk-ministry-of-defense-selects-trellisware-technologies---leading-waveform-developer-to-deliver-more-than-5-000-radios-302708865.html) |
| Silvus Technologies (Motorola Solutions) | StreamCaster MN-MIMO waveform + Spectrum Dominance 2.0 (LPI/LPD, anti-jam); StreamCaster MINI 5200 launched Feb 2026 | [silvustechnologies.com](https://silvustechnologies.com/products/streamcaster-radios/), [Armada MINI 5200](https://www.armadainternational.com/2026/02/silvus-technologies-unveils-streamcaster-mini-5200-tactical-manet-radio/) |
| Rajant | Kinetic Mesh / InstaMesh / BreadCrumb + Cowbell distributed compute | [rajant.com](https://rajant.com/technology/instamesh/) |
| Doodle Labs | Mesh Rider (COFDM); Nano2 launched Apr 2026, vendor-claimed >100 km field-tested and up to 100 Mbps, Sense EW avoidance | [UST Nano2](https://www.unmannedsystemstechnology.com/2026/04/doodle-labs-introduces-new-nano-mesh-rider-radio/) |
| Mobilicom | SkyHopper Tactical (wearable SDR) + SkyHopper MultiBand (1.2-2.7 GHz) + ICE EW/cyber suite | [globenewswire](https://www.globenewswire.com/news-release/2026/05/11/3291906/0/en/mobilicom-launches-skyhopper-tactical-advancing-tactical-drone-and-autonomous-operations-capabilities.html) |
| goTenna | Pro X2 - Aspen Grove Mesh, VHF/UHF, frequency hopping, AES-256 (384-bit for 1:1), MIL-STD-810 | [gotennapro.com](https://gotennapro.com/products/gotenna-pro-x2) |

Strength: mature protocols, hybrid routing, battlefield-proven deployments,
commercial support. Weakness: closed waveform specs, no operator-side bit-exact
verification, no hardware binding (firmware is an abstraction), on-board AI absent
or fp32-conventional.

### Segment 4 - Silicon-bound DePIN (identity anchored to a secure element)

Networks where the right to earn is tied to a physical device via a cryptographic
proof. Today that binding is **identity-only**: a secure element signs "I am this
device", not "I ran this computation".

| Player | Product | Primary URL |
|---|---|---|
| Helium | LoRaWAN + Mobile 5G DePIN; Proof-of-Coverage; device identity via Microchip ATECC608 secure element (ECDSA sign of a unique 72-bit serial) | [docs.helium.com](https://docs.helium.com/), [ECC608-TNGHNT datasheet](https://ww1.microchip.com/downloads/aemDocuments/documents/SCBU/ProductDocuments/DataSheets/ECC608-Trust-and-GO-For-Helium-Network-Data-Sheet-DS40002389.pdf) |
| World Mobile | AirNodes + aerostat (70 km radius); World Mobile Chain (EVM L3 on Base); vendor-reported 100,000+ AirNodes (Feb 2026) | [worldmobile.io](https://worldmobile.io/blog/post/world-mobile-launches-on-base-to-expand-global-web3-wireless-network) |
| Pollen Mobile | CBRS (Band 48) decentralized mobile; PollenCoin; BLiNQ "Sunflower" radios | [pollenmobile.io](https://www.pollenmobile.io/) |
| **Tri-Net (us)** | Silicon-bound mining: `3^27` supply, 7-check claim, `0x47C0` cross-die anchor on SKY26b, four supply arms (transport/compute/coverage/sensor) | [github.com/gHashTag/tri-net](https://github.com/gHashTag/tri-net) |

Strength of the segment for us: the **compute-anchor** slot (chip signs the
computation, not just identity) is unoccupied. Our weakness: no returned silicon
(4 dies submitted, not back), no deployed operators, no paying customer, and the
economic layer is Sepolia-only. The differentiator is a different axis, not a
"better than Helium" claim - and it is `[Open conjecture]` until 2026-12-16.

---

## 2. Wave B — Comparison table (9 columns)

Eight competitors spanning all four segments, plus Tri-Net in row 1. Every cell is
a verifiable fact, a vendor-claimed figure (tagged), or an explicit "no data".

| Player | Waveform | Security (control-plane auth) | Mesh routing | Endurance / power | Open-source | Silicon story | On-board AI | Primary source |
|---|---|---|---|---|---|---|---|---|
| **Tri-Net (us)** | 5.8 GHz baseline + planned OFDM PHY (all `-sim`, PL never flashed) | Data-plane X25519 + ChaCha20-Poly1305 (M1) proven on ARM (`hw`). **Control-plane HELLO-beacon auth built-but-NOT-wired**: `verify_mac`/`is_fresh` exist and are unit-tested but never called on the receive path; daemon sends with `mac_key=None` (public constant). `main` does not build. | ETX + HELLO discovery, Babel-lite (in code, `-sim`, unit-tested only) | Depends on carrier (Zynq-7020 Mini power budget); no endurance run | **Apache-2.0, public** | spec-first `.bit`; 4 dies SKY26b **submitted, not returned**; AX7203 the only board proven-on-silicon | BitNet b1.58 ternary (planned; runnable in SW, not on die) | [github.com/gHashTag/tri-net](https://github.com/gHashTag/tri-net) |
| Persistent MPU5 | Wave Relay (proprietary, in FPGA bitstream) | FIPS / NIAP / CSfC, up to two encryption layers | Wave Relay MANET, no hop limit, node entry <1 s | Carrier-dependent; 10 W radio | Closed | Commodity SoC + FPGA | No data | [persistentsystems.com](https://persistentsystems.com/mpu5-specs/) |
| TrellisWare TSM/Katana | TSM + Katana wideband (proprietary) | Encrypted (FIPS-class); details not public | Barrage-relay MANET | Carrier-dependent | Closed | Commodity | No data | [trellisware.com](https://www.trellisware.com/waveforms/tsm-waveform/) |
| Silvus StreamCaster | MN-MIMO (proprietary) | Spectrum Dominance 2.0 LPI/LPD + anti-jam; AES-class | MN-MIMO mesh, hundreds of nodes | Carrier-dependent | Closed | Commodity | No data | [silvustechnologies.com](https://silvustechnologies.com/products/streamcaster-radios/) |
| Rajant Kinetic Mesh | 2.4/5 GHz + custom | AES-256 | InstaMesh (proprietary, make-before-break) | Carrier-dependent | Closed | Commodity | Cowbell edge compute (not ternary/AI-specific) | [rajant.com](https://rajant.com/technology/instamesh/) |
| Doodle Labs Mesh Rider | COFDM Mesh Rider | AES-256 | Self-forming/healing MANET | Carrier-dependent; vendor-claimed >100 km | Closed (SDK) | Commodity QCA-class | Sense EW (RF avoidance, not inference) | [UST Nano2](https://www.unmannedsystemstechnology.com/2026/04/doodle-labs-introduces-new-nano-mesh-rider-radio/) |
| goTenna Pro X2 | Aspen Grove, VHF/UHF, freq-hopping | AES-256 (384-bit for 1:1 messaging) | Aspen Grove mesh | 9 h battery, 3.5 oz | Closed | Commodity | No data | [gotennapro.com](https://gotennapro.com/products/gotenna-pro-x2) |
| TERASi RU1 | mm-wave >60 GHz (proprietary) | No data (control-plane auth not disclosed) | Self-forming mm-wave mesh | Drone/tripod; vendor-claimed <5 ms latency | Closed | Proprietary mm-wave front-end | No data | [thenextweb.com](https://thenextweb.com/news/swedish-starlink-alternative-ru1-military-communications) |
| Helium | LoRaWAN + 5G (commodity) | Proof-of-Coverage; ATECC608 secure element = **identity** attest only | LoRaWAN / carrier | Mains-powered hotspot | Partly open (protocol) | Commodity + ATECC608 **identity** secure element | No data | [docs.helium.com](https://docs.helium.com/) |

What the table shows:

1. Tri-Net is the only row with a public, open-source, spec-first stack plus
   submitted custom silicon - but also the only row whose control-plane auth is
   currently not wired and whose tree does not build. Both facts are on the table.
2. On-board **ternary** AI is empty for everyone. Rajant's Cowbell and Doodle's
   Sense EW are edge-compute / RF-avoidance, not on-device neural inference.
3. Every DePIN secure-element binding in the field is identity-only. The
   compute-attestation column is genuinely unoccupied - which is the whole moat
   thesis, and also the whole risk (it is unproven until silicon returns).
4. We lose on maturity, endurance, and raw throughput. The fight is not "replace
   MPU5" - it is the niche of verifiable-mesh + on-device ternary inference +
   silicon-anchored economics.

---

## 3. Wave C — Trinity assets to moat mapping

For each Trinity artifact: the moat it opens, and an explicit pre-silicon /
submitted / paper-state tag.

1. **GoldenFloat GF16** ([arXiv:2606.05017](https://arxiv.org/abs/2606.05017)) -
   public bit-exact 16-bit phi-based float. **Moat:** auditable DSP/FEC against
   the closed mm-wave DSP of TERASi and any proprietary MAC block. Operators can
   verify each MAC against published conformance vectors. **Status:** preprint
   published; synthesised for Artix-7 (AX7203 is the one board proven-on-silicon).
2. **84-format numeric catalog** (`gHashTag/paper3-methodology`). **Moat:** a
   formal answer to a regulator's "prove the radio did what you declared" - no
   Segment-3 vendor ships bit-exact conformance vectors. **Status:** paper-state;
   the exact format count is itself under internal audit (raw vs codegen vs
   committed vs paper diverge) - do not quote a single number as settled.
3. **BitNet b1.58** ([arXiv:2402.17764](https://arxiv.org/abs/2402.17764)) -
   multiply-free ternary inference. **Moat:** on-board AI at a low power budget
   where every competitor's AI column is empty (traffic classification,
   neighbour scoring, anomaly detection without float MACs). **Status:** runnable
   in software today; on-die is pre-silicon.
4. **VSA / HDC** (hyperdimensional computing). **Moat:** control-plane resilience
   - HDC-encoded routing/neighbour state tolerates high bit-flip rates where
   classic packet control planes drop out. **Status:** research/`-sim`.
5. **BLAKE3 audit ring** (`tt-trinity-euler` / `tt-trinity-gamma`). **Moat:** a
   cryptographic audit chain between a `.bit`/die artifact and a rewarded event -
   the substance behind "we have a blockchain" that World Mobile / Pollen assert
   without hardware binding. **Status:** design + partial code, `-sim`.
6. **tt-trinity Phi / Euler / Gamma / Corona** - 4 dies **submitted** to SKY26b,
   `0x47C0` cross-die anchor. **Moat:** a physical silicon anchor versus Helium's
   ATECC608 identity-only secure element. **Status: submitted, silicon NOT
   returned.** The strong form - "the chip signs the computation, not just the
   identity" - is `[Open conjecture - falsification: silicon back -> run the
   BitNet ternary benchmark on the die, publish the raw log]`, valid only after
   the 2026-12-16 tape-out.
7. **Trinity CLARA** ([10.5281/zenodo.19227877](https://doi.org/10.5281/zenodo.19227877))
   - ternary accelerator design, ~1 GOPS @ ~50 MHz @ ~1 W. **Moat:** an open,
   published AI-accelerator design against closed in-drone accelerators.
   **Status: projected, pre-silicon** (design published, silicon not fabricated).
8. **t27 spec-first flow** (`.t27` -> Verilog/`.bit`, Yosys/nextpnr/prjxray, no
   Vivado). **Moat:** reproducible builds - hand a regulator or customer the
   `.bit` + toolchain and rebuild it a year later, which Vivado-locked competitors
   cannot. **Status:** in CI; AX7203 is the proven-on-silicon endpoint.
9. **VAK papers** (`gHashTag/trinity-papers-ru`). **Moat:** peer-review
   legitimacy against industry-whitepaper marketing. **Status:** manuscripts;
   submission pending, no arXiv/journal acceptance to cite yet.

**The one-line moat thesis:** every competitor is closed-waveform + firmware-as-
abstraction + identity-only-if-any-hardware-binding. Trinity's assets line up on a
single orthogonal axis - open bit-exact numerics + ternary on-board AI +
silicon-anchored (eventually compute-anchored) economics. The axis is real; the
compute-anchor tip of it is unproven until 2026-12-16.

---

## 4. Three cooperation lanes for the next wave

Each lane names a real, non-competing counterpart and states its own gating risk.
None over-claims; each is honest about the prerequisite that Tri-Net still owes.

### Lane A - Open-PHY interop with openwifi (open-sdr)

- **Scope:** contribute a GF16 bit-exact FEC / beacon-matched-filter block plus
  conformance vectors into the open-source openwifi OFDM PHY.
- **Actor:** `open-sdr/openwifi` maintainers (open Verilog 802.11 on Zynq).
- **Deliverable:** a spec + reference block + conformance CI job, upstreamed as a
  draft PR.
- **Cite:** [github.com/open-sdr/openwifi](https://github.com/open-sdr/openwifi);
  GF16 [arXiv:2606.05017](https://arxiv.org/abs/2606.05017).
- **Effort:** M.
- **Risk:** openwifi targets ZC706-class parts larger than the Zynq-7020 Mini;
  the block may not fit our flight FPGA, and upstream review is slow. GF16 on
  Artix-7 is proven; on a Zynq PL it is not.

### Lane B - An open compute-vs-identity attestation schema for wireless DePIN

- **Scope:** publish an open spec that distinguishes identity-attestation (Helium
  ATECC608 baseline) from compute-attestation, plus a reference on-chain verifier,
  and invite wireless-DePIN projects to a common proof schema.
- **Actor:** wireless-DePIN projects (World Mobile, Pollen) / a DePIN working
  group.
- **Deliverable:** `docs/` spec + reference verifier extending the identity
  baseline.
- **Cite:** [ECC608-TNGHNT datasheet](https://ww1.microchip.com/downloads/aemDocuments/documents/SCBU/ProductDocuments/DataSheets/ECC608-Trust-and-GO-For-Helium-Network-Data-Sheet-DS40002389.pdf)
  as the identity baseline being extended.
- **Effort:** M.
- **Risk:** the compute-attestation half is `[Open conjecture]` until silicon
  returns (2026-12-16). Until then the schema must stay strictly
  identity-attestation-compatible or it ships a claim it cannot back.

### Lane C - Academic co-publication on FANET control-plane resilience

- **Scope:** co-author a measured study of authenticated-HELLO + HDC-encoded
  routing resilience under jamming / high BER, using Tri-Net's beacon-auth (once
  wired) and VSA/HDC.
- **Actor:** a FANET / mesh-routing academic group (e.g. Fraunhofer IIS FANET
  line) or an arXiv preprint.
- **Deliverable:** a preprint + open dataset.
- **Cite:** BitNet [arXiv:2402.17764](https://arxiv.org/abs/2402.17764); the
  existing tri-net auditability-gap note.
- **Effort:** L -> M.
- **Risk:** hard-gated on prerequisites Tri-Net does not yet own - beacon-auth
  must actually be wired (Section 0), `main` must build, and there must be an
  on-device run (today everything is `-sim`). This lane cannot start until that
  debt is paid.

---

## 5. Boundary

- Draft PR only. Never merge. Never push `main`. Human merge only.
- No hardware was touched; no bitstream flashed; no over-the-air transmission.
- No fabricated players, metrics, or node counts. Vendor performance figures are
  tagged vendor-claimed and cited to the vendor.
- The compute-anchor differentiator is `[Open conjecture]`, gated on the TT SKY26b
  tape-out (2026-12-16). It is not asserted as fact anywhere in this report.
- Tri-Net's control-plane auth is reported at its true built-but-not-wired state,
  and `main`'s build failure is stated up front. This report deliberately does not
  present Tri-Net as more finished than the repo is.

---

Anchor: phi^2 + phi^-2 = 3

Three segments are held by competitors. The fourth - silicon-bound, and one day
compute-anchored - is ours and still mostly empty. Three cooperation lanes for the
next wave.
