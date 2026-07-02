# TRI-NET — Science-Driven Strengthening

**Trinity Project · "Starlink without satellites"** · self-organizing mesh of relay drones + fixed nodes sharing one internet uplink
Anchor: φ² + φ⁻² = 3. State as of 2026-07-01. Boards: AX7203 (Artix-7 xc7a200t, ground/compute, PROVEN) + P201/P203 Mini (Zynq-7020 xc7z020 + AD9361 SDR, flying node, greenfield). trios-mesh M1 crypto core done + host-tested (-sim), never on hardware.

> **Honesty guardrails.** Every FPGA/ASIC performance number from our own Trinity assets is **PROJECTED / pre-silicon**, not measured — no tt-trinity die has returned from foundry. GoldenFloat papers make **no per-rung accuracy-superiority claim**; the honest GF16 value is *compact width + proven FPGA codec + ready Rust FFI*, not accuracy. The self-heal convergence threshold is still UNDEFINED until instrumented. Where an item needs flight hardware, GPS, or an external RF part, it is marked `auto=false` and cannot be closed in the Rust repo today.

---

## (a) External literature → concrete improvements

### Routing / mesh (all `auto=true`, pure software in trios-mesh)

| # | Improvement | Target file | Mechanism from literature | Citation |
|---|---|---|---|---|
| R1 | Replace flat sliding-window delivery ratio with **EWMA/WMEWMA** (α≈0.3–0.5); bootstrap fresh neighbors with an optimistic prior instead of 0.0→∞ ETX | `src/routing.rs` `DeliveryRatio` | Uniform-window mean is the slow-reacting form; at ~12 m/s UAV cruise, topology changes faster than the averaging window. WMEWMA stays responsive yet filters transient PRR noise. | Rosati et al., arXiv:1307.6350; WMEWMA (Woo & Culler); arXiv:1311.3746 |
| R2 | Add **multi-hop additive path ETX + Babel-style feasibility condition** (per-source seq, accept route only if strictly better/fresher) | `src/routing.rs` (new table) | `best_next_hop()` ranks only *direct* neighbors — no path metric, no loop-avoidance, in a 3–8 node relay mesh. Real FANET flights: Babel > OLSR > BATMAN-adv. | Guillén-Pérez 2021 doi:10.3390/APP11104363; Babel RFC 8966 |
| R3 | **Fast failure detection**: consume HELLO `seq` gaps (BFD-style detect-multiplier); after *k* misses force ETX→∞ and recompute | `src/discovery.rs` + `src/daemon.rs` | Routing dead-timers alone rarely detect loss < 2 s; counting missed beacons gives sub-second detection. `Hello.seq` already exists but `daemon.rs` ignores it. Bounds self-heal to *k·beacon_interval*. | BFD RFC 5880; Cisco/Arista hello-multiplier |
| R4 | Add **beacon scheduler + neighbor-expiry sweep** to the daemon so the ETX window advances on wall-clock, not only on received HELLOs | `src/daemon.rs` | Today `record()` only fires on received HELLOs, so a dead neighbor never accumulates misses. Prerequisite for R1 and R3 to behave. | Guillén-Pérez 2021 doi:10.3390/APP11104363; BFD RFC 5880 |
| R5 | Upgrade ETX→**ETT** using SDR-reported per-link rate: `ETT = ETX × (frame_bytes / link_rate_bps)`, fall back to ETX when rate absent | `src/routing.rs` `LinkStats::etx→ett` | ETX ignores bandwidth; ETT/WCETT favor high-rate low-loss links and model same-channel interference on the shared 5.8 GHz triangle. Metric code is host-testable now; *effective* only once M2 radio feeds real rate (rate plumbing HW-gated). | Draves/Padhye/Zill ETT/WCETT, MobiCom 2004; doi:10.1007/978-1-4614-6154-8_79 |
| R6 | **Node-disjoint backup next-hop** (`best_next_hop → ranked_next_hops`); hot-swap on the R3 dead signal | `src/routing.rs` (+ `src/wire.rs` for source-route field → bump VERSION) | Triangle gives every node 2 candidates but only one is used, so a break stalls until reconvergence. LB-OPAR: up to +30% flow success, +4× throughput from load-balanced near-disjoint paths. O(\|E\|²) trivial at 8 nodes. | Sharma et al. LB-OPAR arXiv:2205.07126; IEEE 4428723 |
| R7 | **Mobility-predictive metric**: add position+velocity to HELLO, compute Link-Expiration-Time, bias toward longer-lived links | `src/discovery.rs` + `src/routing.rs` | Metric has zero mobility awareness. PARRoT folds LET into an RL discount γ. **Blocked without a real position source (MAVLink/Pixhawk GPS)** → `auto=false`. | Sliwa et al. PARRoT arXiv:2012.05490; MDPI Electronics 14(7):1456 2025 |
| R8 | **Keep sim/demo topology a triangle, not a chain**; place fixed anchor near Galkin optimal-height | tests / smoke harness | Triangle beats chain under half-duplex and is the precondition for R6 (2 next-hop candidates per node). | Lakew et al. IEEE COMST 2020 doi:10.1109/COMST.2020.2982452; Galkin 2017 arXiv:1710.03701 |

### PHY / radio (mostly `auto=false` — RTL/hardware; one host-model is `auto=true`)

| # | Improvement | Target | Mechanism | Citation |
|---|---|---|---|---|
| P1 | **Port openwifi 802.11a/g/n OFDM PHY to xc7z020** instead of greenfield RTL (64-pt FFT, 20 MHz, BPSK..64-QAM, conv+Viterbi already synthesizes on adrv9364z7020) | Zynq PL RTL | Collapses the #1 tech risk from "design from scratch" to "port". Measured OFDM Rx cost ≈15% LUT / ~8% DSP (802.11p on ZC702) leaves ample room for FEC/mesh/crypto. **Caveat: openwifi's Viterbi is a Xilinx eval-license core that halts after ~2 h — swap before fielding.** | github.com/open-sdr/openwifi; arXiv:2003.09525 |
| P2 | **Host-side single-carrier + OFDM modem sim** to fix MCS thresholds, CP length, FFT size and validate the 5.8 GHz link budget (incl. 4–7 dB PAPR back-off) before any RTL | Host (`-sim`) | Pure software, testable like the existing crypto core; de-risks RTL by fixing parameters up front and lets us numerically compare OFDM vs SC for the open-sky channel. **`auto=true`.** | wirelesspi.com/why-ofdm-is-used-in-uav-links; etri.15.0114.1194; NASA ACM 20170001299 |
| P3 | **DFT-spread-OFDM (SC-FDMA)** on the uplink/relay Tx to reclaim 4–7 dB PA back-off | Mini Tx PHY | OFDM's high PAPR forces 4–7 dB back-off, compounding the weak 10–15 dBm PA (→~4–9 dBm avg). SC-FDMA keeps freq-domain equalization at lower PAPR (LTE uplink uses it exactly for power-limited terminals). | mathworks SC-FDMA vs OFDM; etri.15.0114.1194 |
| P4 | **Schmidl-Cox preamble sync** as OFDM acquisition front-end | Mini Rx PHY | Two-identical-half preamble → joint timing+CFO in one symbol; robust at −6 dB AWGN; proven fully-parallel on XC7Z045 @200 MHz. Matches the range-limited weak-PA link. | GNU Radio Schmidl-&-Cox; arXiv:1905.07792 |
| P5 | **Stage FEC**: ship convolutional+Viterbi first (free with openwifi), add single time-multiplexed QC-LDPC only if the link budget demands it | Mini PHY FEC | LDPC is DSP/LUT-bound (~25.6% LUTs per core; ~18% LUT/5% DSP/11% BRAM); parallel cores exhaust the 7020. Single time-shared core keeps combined PL under the ~50% feasibility rule. | arXiv:1007.4465; researchgate 267763384/358114492 |
| P6 | **SNR/CSI-feedback AMC** carried in the trios-mesh authenticated header | trios-mesh MAC + Mini PHY | Mesh link distances change with drone motion, so a fixed MCS is wrong. AMC drops to BPSK½ at range, climbs to 64-QAM up close. Header already exists to carry CSI. Thresholds from P2. | NASA ACM 20170001299; arXiv:2307.07075 |
| P7 | **Size TDMA slots for the >37 µs AD9361 TDD turnaround** (PLL relock ~15 µs + DAC ~18 µs); keep PLL/DAC powered, use multi-ms slots + Even/Odd directional spatial reuse | trios-mesh MAC + AD9361 config | Turnaround is the floor on slot granularity and the root of ~50% half-duplex-per-hop loss. Directional antennas let non-adjacent triangle edges transmit concurrently. | ADI TDD switching-time; arXiv:2009.13707; arXiv:1509.07329 |
| P8 | **External PA (+27..+33 dBm) + LNA + 6 dBi directional antennas** — mandatory link-budget fix, bounded by 5.8 GHz EIRP rules | Mini RF front-end | FSPL 108 dB@1 km / 128 dB@10 km; sensitivity ~−93.8 dBm (BPSK½). No modem/FEC choice saves the link on the onboard PA alone. **In free flight the ≤100 mW (TH/SG) licensed-by-rule ceiling means directional-antenna gain, not raw PA watts, is the legal range lever**; full PA gain applies on tethered/licensed links. | internetsociety link-budget; reversepcb FSPL |

### Security (mostly `auto=true` in Rust, gated on the static-key auth landing first)

| # | Improvement | Target | Mechanism | Citation |
|---|---|---|---|---|
| S1 | **Static-key mutual auth (Noise-XX) over existing X25519+ChaCha20-Poly1305**; bind NodeId to a persistent static key | `src/crypto.rs` | Today's handshake is unauthenticated ephemeral-ephemeral DH (Noise "NN"): `complete()` trusts ANY peer key → MITM/Sybil indistinguishable from a real peer. libp2p runs Noise-XX over these exact primitives. **Single largest crypto gap.** | noiseprotocol.org/noise.pdf; libp2p Noise spec |
| S2 | **Gate ETX/routing on completed auth + MAC/sign HELLOs**; one static key = one identity | `src/routing.rs` + `src/discovery.rs` | Plaintext HELLOs let an attacker forge `src`, lie in the `heard` list to drive its ETX→1.0, become `best_next_hop()`, then blackhole — the classic AODV false-metric attack. Collapses Sybil, rate-limits HELLO floods that drain the endurance-limited node. | SAODV ieee 5376147; arXiv:1407.3987 |
| S3 | **Authenticate HELLO beacons + freshness (seq+timestamp under MAC)** | `src/discovery.rs` + `src/wire.rs` | `FrameKind::Hello` exists but HELLOs bypass AEAD and carry only a plaintext u32 seq with no replay check → old HELLOs resurrect dead links / skew ETX history. | SAODV non-mutable-field signing; libsodium replay-window |
| S4 | **Hash-chain-protect TTL/hop-count** so relays decrement-only, never claim a shorter path | `src/routing.rs` + `src/wire.rs` | SAODV seals a chain anchor; each hop reveals one preimage so hop-count can advance but never roll back → prevents shorter-path route hijack. | SAODV hash-chain ieee 5376147 |
| S5 | **Periodic rekey / HKDF symmetric ratchet + cap frames-per-key below ChaCha's 2³² block limit** | `src/crypto.rs` | One HKDF key for the whole session, never rekeyed; long high-throughput session approaches the 256 GB/key keystream boundary. Ratchet gives within-session forward + post-compromise secrecy for a capturable node. | noiseprotocol.org (rekey); libsodium; blog.malosdaf.me nonce-reuse |
| S6 | **Zeroize all key material** (HKDF output, ephemeral secrets, session key) via `zeroize` | `src/crypto.rs` | Derived `[u8;32]` and `EphemeralSecret` live in plain memory; a memory disclosure on the ARM node leaks the live key. Cheap, purely additive. | BearSSL constant-time; RustCrypto `zeroize` |
| S7 | **Rate-limit / cheap-reject unknown-src frames before allocation**; bounded neighbor table | `src/daemon.rs` | `open_data` looks up session by CLAIMED src; attacker spams arbitrary-src frames to force lookups/table growth (cheap DoS on the CPU/power-limited node). | arXiv:1407.3987; researchgate 308541512 |
| S8 | **Widen/parametrize AEAD replay window** (128/256-bit bitmap or config WIDTH) + heavy-reorder test | `src/crypto.rs` | Fixed 64-frame window can false-reject legitimately reordered frames on the lossy multi-hop path (~50% half-duplex degradation increases reordering). | crypto.rs ReplayWindow WIDTH=64; libsodium |
| S9 | **Jamming-detection-to-reroute hook**: consume RSSI/LQI/CN0 from the SDR driver, run a cheap online detector, raise ETX→∞ on suspected jam | `src/routing.rs` + SDR driver iface | Anti-jam PHY (FHSS/DSSS) is hardware; the Rust glue that turns a jam signal into a re-route is software and feeds the self-heal gate. | mdpi 24/13/4210; arXiv:2508.11687 |
| S10 | **Audit RustCrypto backends stay portable-constant-time on Cortex-A9** (CI check, no secret-dependent asm/branch, no early-return-on-tag-mismatch) | `src/crypto.rs` + CI | ChaCha20 is naturally constant-time (no table lookups); Cortex-A9 has no AES-NI so ChaCha is the correct anti-timing choice. Cheap assurance for real silicon. | DATE 2017 ChaCha20-Poly1305 embedded; bearssl constant-time |

**Security items `auto=false` (hardware/regulatory):** FHSS/DSSS spread-spectrum anti-jam PHY on Zynq PL + AD9361 (XL, top-risk track); compliant cryptographically-isolated Remote-ID broadcast module (ASTM F3411-22a is unauthenticated/spoofable — treat inbound Remote-ID as untrusted, keep it isolated from mesh keys); GPS spoof/jam detection lives in the flight stack (do NOT let raw GPS drive routing without an integrity flag).

---

## (b) Weak spots → strengths (severity · mitigation · physics-vs-addressable)

| Weak spot | Sev | Nature | Mitigation → strength conversion |
|---|---|---|---|
| Free-flight endurance 20–45 min | HIGH | Physics (battery) — **not codeable** | **Tether the uplink/anchor node** (continuous ground power, ~12 kW/150 m; 100+ h flights; AT&T Flying-COW precedent). Triangle needs only ONE mobile relay → tethered anchor becomes a persistent mast. |
| Weak Mini PA 10–15 dBm → short range | HIGH | Physics/procurement — **not codeable** | External PA+LNA + **directional antennas** (one procurement fixes PA range + spatial reuse + interference). In free flight ≤100 mW cap ⇒ antenna gain is the legal lever; full PA on tethered/licensed links. **P3 DFT-spread reclaims 4–7 dB in software-defined waveform.** |
| Half-duplex ~50% per-hop | MED | Part-addressable | **TDMA slot scheduler** in trios-mesh MAC (`auto=true`) + directional Even/Odd spatial reuse + triangle-not-chain (≤2 hops). Turns generic penalty into triangle-specific advantage. |
| OFDM demod fit in 85K-LC/220-DSP PL | TOP greenfield | Addressable (RTL) | De-risked: 802.11p OFDM Rx = 18/220 DSP (8.2%) on same Zynq family; **port openwifi (P1)** rather than greenfield. FFT is only a few hundred LUTs. SC fallback is the first-light hedge. |
| No FEC/LDPC yet | greenfield | Addressable (RTL) | **Stage FEC (P5)**: Viterbi free with openwifi now; single time-multiplexed LDPC later. FEC — not OFDM — is the real 7020 bottleneck. |
| Self-heal convergence threshold UNDEFINED | greenfield | Codeable/test-definable | Adopt roadmap draft **<5 s link-loss re-route / <10 s node-off** as the DEMO-GATE metric; bound it via R3 (*k·beacon_interval*) and instrument in the daemon. Turns undefined risk into a GO/NO-GO number. |
| Single uplink point | MED | Codeable | **Multi-uplink ETX-weighted default-route failover** in M4 (`auto=true`, 2nd modem only). Triangle already provides path redundancy. |
| BVLOS / spectrum regulatory | HIGH | Regulatory — **not codeable** | Tethered anchor is generally NOT BVLOS; only the one free-flyer needs the ~3-mo waiver, operating within ≤100 mW licensed-by-rule. |
| FPGA thermal + AX7203 not flight-ready + single-GbE | MED×3 | Architectural | **Role split**: AX7203 = tethered/ground (2×GbE backhaul+access split, radiator, unlimited power); light Mini = free-flyer (low thermal). Three weak spots collapse into one clean split. |
| Security jamming/injection | MED | Part codeable | Injection already mitigated + host-tested (AEAD, authenticated header as AAD, replay window). Remaining: FHSS PHY (hardware) + S1–S4 routing hardening (Rust). |
| trios-mesh never on hardware | greenfield | Codeable/sequencing | **Graduate M1 crypto on the Mini ARM-Linux PS first** (needs only Linux userspace, not AD9361/PL) — retires mesh-SW risk in parallel with the high-risk OFDM PL work, not in series. |

---

## (c) How OUR Trinity papers strengthen the project *(headline)*

Our own GoldenFloat / ternary / VSA / tt-silicon assets are the differentiator vs Starlink: **an owned open-silicon compute path, not a leased constellation.** Each maps to a concrete TRI-NET module with a *realistic* (honest) gain. All FPGA/ASIC numbers are **projected/pre-silicon** unless from a returned die (none have returned).

| Asset | Mechanism | TRI-NET module | Realistic gain (honest) | Auto? |
|---|---|---|---|---|
| **GoldenFloat GF16** (arXiv:2606.05017; zig-golden-float `rust/goldenfloat-sys`, `phi_dot`/`phi_fma` C-ABI) — 323 MHz on Artix-7 XC7A35T, 35/35 PASS | Add a **GF16 Rust DSP model** of the OFDM FFT/equalizer taps that maps 1:1 to t27-emitted Verilog | `src/` new `gf16` dsp module → later Zynq PL datapath | **Width, not accuracy**: 16-bit vs fp32 halves multiplier width ⇒ more parallel taps per DSP48, directly attacking the top OFDM-fit risk. Paper makes NO accuracy-superiority claim. Sim-first (never on HW). Must validate against ml_dtypes-cross-checked conformance vectors. | true |
| **Ternary / BitNet b1.58** (tt-trinity-gamma `bitnet_encoder.v`, `k3_alu.v`, arXiv:2402.17764; R-SI-1 no-`*` audit; GFTernary) — add-only, ~1.58 bit/trit, ~20× memory vs fp32 | **Multiply-free ternary RF-interference/jam classifier stub** consuming AD9361 spectral features → jam/clear + suggested channel/TX-power | Onboard AI → feeds `src/routing.rs` (S9 adaptive input) | Runs onboard **without stealing DSP48 from the OFDM datapath** (add-only). Mitigates jamming + weak-PA range via smarter control, not more watts. Qualitative until trained on real captures — ship Rust stub with `[Conj]` label; FPGA accel later via t27 `gen-bitnet-bundle`. | true |
| **VSA / HDC** (zig-hdc HRR/bundle/similarity over GF16; tt-trinity-gamma VSA PE mesh) — hypervector survives ~30% bit-flips via nearest-neighbor cleanup | Encode neighbor IDs / anti-jam channel fingerprints as **bundled hypervectors** layered on ETX | `src/routing.rs` + `src/discovery.rs` | Graceful degradation instead of link drops under noisy/jammed neighbor state. **A robustness heuristic, NOT a proven convergence guarantee** (self-heal threshold still UNDEFINED) — prototype and measure in `-sim`, do not claim. | true |
| **BLAKE3 + append-only audit ring** (tt-trinity-euler/gamma `blake3_anchor.v`, `audit_log_ring_buffer.v`, `proof_trace_writer.v`) | **BLAKE3-hashed tamper-evident audit log** of C2/telemetry frames (Rust now, FPGA offload later) | `src/crypto.rs` / `src/wire.rs` audit log; Zynq PL offload (future) | Integrity offload + auditable command trail strengthening the **BVLOS/CAAS regulatory case**. Gain is integrity/audit, not new crypto strength — AEAD already gives confidentiality/authenticity. Rust log `auto=true`; HW BLAKE3 future silicon. | true (Rust) |
| **84-format conformance catalog + Corona oracle + 0x47C0 anchor** (arXiv:2606.09686; paper3-methodology; tt-trinity-corona 17 decoders→FP32; t27 `FORMAT-SPEC-001.json`) — SHA-256-fingerprinted, ml_dtypes-cross-validated bit-exact vectors; 3.0=φ²+φ⁻² universal check | Import golden vectors + `dot4(1,2,3,4)=0x47C0` anchor as **CI golden tests** for the GF16 datapath | trios-mesh CI + gf16 tests | Single source-of-truth so the datapath is **bit-identical in -sim and on the Zynq PL** — directly de-risks the "never run on hardware" gap. Low effort, high verification leverage, no perf claim. | true |
| **tt-trinity Phi/Euler/Gamma/Corona ASIC + D2D holo-mesh** (four SUBMITTED TinyTapeout dies; die-to-die mesh mirrors drone-to-drone mesh) | Narrative/strategy asset: **"own-chip vs Starlink" differentiator** | Report/pitch (not a code module) | The concrete answer to "why not just Starlink." **MUST be presented as SUBMITTED/PROJECTED — no die returned, no measured TOPS, no per-shuttle DOI**, matching the repos' own disclaimers. Keep OFAC-listed parties out of US pitches. | false |
| **t27 spec-first flow** (Yosys→nextpnr→prjxray→.bit, no Vivado; BitNet HLS 9/9 bundle: AXI slave+DMA+IRQ+engine_top; host Rust driver) | Production bridge: same open flow targets Zynq-7020 PL; BitNet HLS bundle is a ready **AXI-attached ternary-classifier accelerator** the trios-mesh Rust driver can talk to | Zynq PL accel + trios-mesh host driver | Turns the ternary-classifier idea from paper concept into an actual FPGA-attached datapath. RTL/bitstream work → `auto=false`, but the Rust host-driver side is testable early. | false (RTL) |

**Net story.** External science tells us *what to build* (EWMA/Babel routing, openwifi OFDM, SC-FDMA, Noise-XX, SAODV). Our Trinity assets tell us *how to build it uniquely*: a **GF16 16-bit datapath** that eases the OFDM-fit risk, **add-only ternary AI** for onboard jam-adaptation that costs zero DSP48, **VSA** for noise-robust routing, **BLAKE3 audit** for BVLOS evidence, a **bit-exact conformance regime** so sim==silicon, and an **owned-silicon roadmap** as the anti-Starlink differentiator — all presented pre-silicon and honestly.

---

## (d) References

**Routing:** Rosati et al., Speed-Aware Routing for UAV Ad-Hoc Networks, arXiv:1307.6350 · WMEWMA (Woo & Culler) · arXiv:1311.3746 · Guillén-Pérez et al. 2021, Applied Sciences 11(10):4363, doi:10.3390/APP11104363 · Babel RFC 8966 · BFD RFC 5880 · De Couto ETX (MobiCom 2003); Draves/Padhye/Zill ETT/WCETT (MobiCom 2004); doi:10.1007/978-1-4614-6154-8_79; arXiv:1011.1584 · Sliwa et al. PARRoT arXiv:2012.05490; arXiv:2107.06190; MDPI Electronics 14(7):1456 2025 · Sharma et al. LB-OPAR arXiv:2205.07126; IEEE 4428723; arXiv:2601.10299 · Lakew et al. IEEE COMST 2020 doi:10.1109/COMST.2020.2982452 · Galkin/Kibilda/DaSilva 2017 arXiv:1710.03701.

**PHY:** ADI AN-2597 / ADSW-OFDMS2M · openwifi github.com/open-sdr/openwifi · arXiv:2003.09525 (802.11p Rx on Zynq) · Xilinx FFT PG109; ej-eng.org/1501 · wirelesspi.com/why-ofdm-is-used-in-uav-links; mathworks SC-FDMA vs OFDM; onlinelibrary.wiley.com etrij.15.0114.1194 · GNU Radio Schmidl-&-Cox; arXiv:1905.07792 · arXiv:1007.4465; researchgate 358114492/267763384 · ADI TDD switching-time; arXiv:2009.13707; arXiv:1509.07329 · NASA ACM 20170001299; arXiv:2307.07075 · internetsociety link-budget; reversepcb FSPL.

**Security:** noiseprotocol.org/noise.pdf; libp2p Noise spec; iacr.org pkc2020/12110122 · RFC 8439; libsodium IETF ChaCha20-Poly1305; blog.malosdaf.me nonce-reuse; draft-irtf-cfrg-xchacha-03 · DATE 2017 ChaCha20-Poly1305 embedded; bearssl.org/constanttime.html · SAODV ieee 5376147; sciencedirect S1084804512000331; AODVSEC arXiv:1208.1959 · arXiv:1407.3987; Sybil academia.edu/35810844; researchgate 308541512 · mdpi 2504-446X/8/12/743; mdpi 1424-8220/24/13/4210; arXiv:2508.11687; etrij.2024-0369 · GNSS spoof: arXiv:2501.02352; mdpi 24/18/6156; mdpi 25/13/4045 · FAA Remote-ID / ASTM F3411 (dslrpros, matestlabs, Open Drone ID vulns).

**Endurance/regulatory:** beyondsky.xyz tethered-drone; zenithaerotech.com tethered; hologram.io BVLOS; oig.dot.gov FAA BVLOS Final Report 2025.

**Our Trinity assets (github gHashTag):** arXiv:2606.05017 (GoldenFloat GF16); arXiv:2606.09686 (84-format catalog); zig-golden-float, GoldenFloat.jl, paper3-methodology, arith2027-goldenfloat · tt-trinity-{phi,euler,gamma,corona} · arXiv:2402.17764 (BitNet b1.58); zig-hdc; t27 (FORMAT-SPEC-001.json, BitNet HLS bundle); trinity-fpga openXC7.

---

## Improvement backlog (priority-ranked)

`auto` = implementable in this Rust repo today (the loop/cron work these); `hw` = needs flight hardware / RTL / RF / regulatory (human).

| P | ID | Item | Area | Type | Issue |
|--:|----|------|------|------|-------|
| 1 | B01 | Static-key mutual auth (Noise-XX) + bind NodeId to static key | crypto | auto | [#1](https://github.com/gHashTag/trios-mesh/issues/1) |
| 2 | B02 | Gate ETX/routing on completed auth; MAC/sign HELLOs (kill Sybil + blac | routing | auto | [#2](https://github.com/gHashTag/trios-mesh/issues/2) |
| 3 | B03 | Fast failure detection via HELLO seq gaps (BFD-style) -> ETX=INF, reco | routing | auto | [#3](https://github.com/gHashTag/trios-mesh/issues/3) |
| 4 | B04 | Beacon scheduler + neighbor-expiry sweep in the daemon | routing | auto | [#4](https://github.com/gHashTag/trios-mesh/issues/4) |
| 5 | B05 | Replace flat-window delivery ratio with EWMA/WMEWMA + optimistic boots | routing | auto | [#5](https://github.com/gHashTag/trios-mesh/issues/5) |
| 6 | B06 | Multi-hop additive path ETX + Babel-style feasibility condition | routing | auto | [#6](https://github.com/gHashTag/trios-mesh/issues/6) |
| 7 | B07 | Host-side single-carrier + OFDM modem sim to fix MCS/link-budget befor | PHY (host model) | auto | [#7](https://github.com/gHashTag/trios-mesh/issues/7) |
| 8 | B08 | GF16 Rust DSP model of the OFDM FFT/equalizer datapath (sim-first) | FPGA DSP datapath (host model) | auto | [#8](https://github.com/gHashTag/trios-mesh/issues/8) |
| 9 | B09 | Authenticate HELLO beacons + freshness (seq+timestamp under MAC) | security/routing | auto | [#9](https://github.com/gHashTag/trios-mesh/issues/9) |
| 10 | B10 | Periodic rekey / HKDF ratchet + zeroize all key material | crypto | auto | [#10](https://github.com/gHashTag/trios-mesh/issues/10) |
| 11 | B11 | Define + instrument M5 self-heal convergence pass/fail metric | self-heal / DEMO GATE | auto | — |
| 12 | B12 | Node-disjoint backup next-hop for instant failover + load spread | routing | auto | — |
| 13 | B13 | Ternary (BitNet b1.58) RF-interference/jam classifier stub + ETX jam h | onboard AI / routing | auto | — |
| 14 | B14 | Adopt 84-format conformance vectors + 0x47C0 anchor as datapath golden | verification (sim-vs-hardware parity) | auto | — |
| 15 | B15 | Multi-uplink ETX-weighted default-route failover (M4) | uplink redundancy | auto | — |
| 16 | B16 | BLAKE3 tamper-evident audit log of C2/telemetry frames (Rust now, FPGA | security + BVLOS evidence | auto | — |
| 17 | B17 | Rate-limit unknown-src frames before allocation + widen/parametrize re | crypto/DoS | auto | — |
| 18 | B18 | Keep sim/demo topology a triangle (not a chain) + constant-time CI aud | topology + crypto CI | auto | — |
| 19 | B19 | Graduate M1 crypto on the Mini ARM-Linux PS independently of the radio | greenfield HW validation / sequencing | **hw** | — |
| 20 | B20 | Port openwifi OFDM PHY to xc7z020 + stage FEC (Viterbi then time-mux L | PHY (FPGA RTL) | **hw** | — |
| 21 | B21 | External PA+LNA + directional antennas @5.8GHz + DFT-spread-OFDM wavef | RF hardware / PHY waveform | **hw** | — |
| 22 | B22 | Tether the uplink/anchor node; file BVLOS waiver only for the single f | topology/endurance + regulatory | **hw** | — |

## Our Trinity research → TRI-NET (force-multiplier map)

| Asset | Mechanism | Plugs into | Effort | Auto |
|-------|-----------|-----------|--------|------|
| GoldenFloat GF16 (arXiv:2606.05017; zig-golden-float rust/goldenfloat-sys, phi_dot/phi_fma C-ABI; 323 MHz Artix-7 XC7A35T, 35/35 PASS) | 16-bit phi-derived FP datapath: half the multiplier width vs fp32 => more parallel FFT/equ | trios-mesh src/ new gf16 DSP model of OFDM FFT/equalizer taps (sim-first) -> later P201/P203 Mini Zynq-7020 PL radio datapath | M | yes |
| Ternary / BitNet b1.58 (tt-trinity-gamma bitnet_encoder.v, k3_alu.v, arXiv:2402.17764; R-SI-1 no-star audit; zig-golden-float GFTernary) | Add-only multiply-free ternary {-1,0,+1} inference (~1.58 bit/trit, ~20x memory vs fp32) r | P201/P203 Mini onboard AI: ternary RF-interference/jam classifier stub feeding trios-mesh src/routing.rs adaptive input (S9). FPGA accel later via t27 gen-bitnet-bundle. | M | yes |
| VSA / HDC (zig-hdc HRR/bundle/similarity over GF16; tt-trinity-gamma VSA PE mesh) | Hypervectors clean up to the correct symbol under ~30% bit corruption via nearest-neighbor | trios-mesh src/routing.rs + src/discovery.rs: neighbor IDs / anti-jam channel fingerprints as bundled hypervectors layered on the ETX metric; measure convergence in -sim. | M | yes |
| BLAKE3 + append-only audit ring (tt-trinity-euler/gamma blake3_anchor.v, audit_log_ring_buffer.v, proof_trace_writer.v) | BLAKE3-hashed tamper-evident append-only log of C2/telemetry frames; integrity offload + a | trios-mesh src/crypto.rs / src/wire.rs Rust audit log now (auto); Zynq PL BLAKE3 offload future silicon. Strengthens injection defense + BVLOS/CAAS regulatory evidence. | S | yes |
| 84-format conformance catalog + Corona oracle + 0x47C0 anchor (arXiv:2606.09686; paper3-methodology; tt-trinity-corona 17 decoders->FP32; t27 FORMAT-SPEC-001.json) | SHA-256-fingerprinted, ml_dtypes-cross-validated bit-exact numeric vectors; universal chec | trios-mesh CI + gf16 DSP module golden tests -> de-risks the 'never run on hardware' sim-vs-hardware parity gap. | S | yes |
| t27 spec-first FPGA flow + BitNet HLS bundle (Yosys->nextpnr->prjxray->.bit, no Vivado; AXI slave+DMA+IRQ+engine_top; host Rust driver) | Same open flow that closed GF16 on Artix-7 targets the Zynq-7020 PL; BitNet HLS bundle is  | Zynq PL ternary-classifier accelerator + trios-mesh host driver (RTL/bitstream => auto=false; Rust host-driver side testable early). | L | no |
| tt-trinity Phi/Euler/Gamma/Corona ASIC + D2D holo-mesh (four SUBMITTED TinyTapeout dies; die-to-die mesh mirrors drone-to-drone mesh) | Owned open-silicon compute path with a chip-to-chip mesh protocol conceptually mirroring t | Report/pitch strategy narrative (not a code module); keep OFAC-listed parties out of US pitches. | S | no |

> **Honesty:** every ASIC/silicon number is pre-silicon projection (no tt-trinity die back from foundry). GF16's honest value = compact width + proven FPGA codec + Rust FFI, not accuracy superiority. Self-heal convergence threshold stays UNDEFINED until instrumented (B11).

