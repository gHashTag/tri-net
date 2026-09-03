# tri-net

**TRI-NET mesh + DePIN node** — encrypted, self-routing IP-over-radio on the
P201/P203 **Zynq-7020 Mini**, doubling as a Helium-style DePIN-node with four
supply-side arms (transport / compute / coverage / sensor).
Part of the Trinity Project. Anchor: **φ² + φ⁻² = 3**.

> 🌍 **Civilian connectivity.** tri-net is built for peaceful, civilian use — rural & remote internet access, disaster-relief communications, and community-owned mesh networks. Open-source, encrypted, self-healing.


> Naming: this is the **mesh internet-delivery** track plus the DePIN economic
> layer on top. Distinct from the ternary-computing "TRI-NET" silicon-node work in
> `gHashTag/trinity`, `gHashTag/tt-trinity-*`.

---

## Status (2026-07-04)

| Layer | State | Evidence |
|---|---|---|
| M1 crypto on ARM (X25519 + ChaCha20-Poly1305) | **hw** ✅ | `smoke/M1_RESULTS.md` — armv7l static binary 534 604 B, sha256 `e5abc335…7290a`, RC=0, 2026-07-01 |
| AD9361 5.8 GHz PHY digital loopback | **hw** ✅ | `radio/README.md` — LO 5.8 GHz, FFT peak +0.999 MHz, SNR 108.6 dB, 2026-07-01 |
| Three P201/P203 Mini boards physically connected | **hw** ✅ | User confirmation 2026-07-04 |
| M2 TUN/IP routing (ETX + discovery) | `-sim` | Rust unit tests, no on-device run |
| M3 iperf3 over 2 hops (bench attenuators) | `-sim` | Not run |
| M4 3-node triangle, shared uplink (P2 DEMO GATE) | `-sim` | Not run |
| M5 self-healing convergence measured | undefined | B11 not landed |
| trinity-contracts deployment (Base L2) | Sepolia only | Mainnet Genesis Day not reached |
| Trinity silicon (1 GOPS @ 50 MHz @ 1 W) | NO ROUTE | no die exists, none is scheduled; the earlier shuttle route is closed |

Every unverified performance number keeps its `-sim` marker. On-device evidence
lives under `smoke/` and `radio/`. All Trinity silicon-anchored DePIN claims
are `[Open conjecture]` until the die comes back — falsification path: run the
BitNet-ternary benchmark on returned silicon, publish the raw log.

---

## What Tri-Net does

A single box (`P203 Mini` = Zynq-7020 + AD9361 SDR + GPS/PPS) fills two roles
at the same time:

1. **Mesh internet-delivery** — "Starlink without satellites": a network of
   mobile relays and ground nodes sharing one uplink over a self-routing mesh.
2. **DePIN node** (Helium-style + edge compute) — the operator earns TRI tokens
   for real contribution to four arms of the network, each one secured by a
   cryptographic signature from a Trinity chip.

### Four supply-side arms on one P203 Mini

| Arm | What it does | proof-payload | chip sigs |
|---|---|---|---|
| **Transport** | mesh-relay bandwidth | (from, to, bytes, ts_start, ts_end) | 2-of-3 Phi |
| **Compute** | ternary edge inference (BitNet) | (model_hash, input_hash, output_hash, ops) | 3-of-3 Phi+Euler+Gamma |
| **Coverage** | 5.8 GHz PoC beacon challenge-response | (challenger, responder, witness, rssi, tof) | 3-of-3 cross-die φ |
| **Sensor** | RF spectrum atlas + GPS-jam detection | (snapshot_hash, gps_time, location_hash) | 1-of-3 any |

All four arms settle through the same `MiningPool.claimReward()` — seven
checks, none of them bypassable. Full description in `docs/WAVE_DEPIN_2026-07-04.md`.

---

## Three boards as the base of the network

Three `P203 Mini` boards are assembled, powered, and already carrying verified
crypto traffic (see `smoke/M1_RESULTS.md`). That is the minimum base for:

- **P2 DEMO GATE** (M4 + M5) — a three-node triangle, one shared uplink, and a
  measurable mesh self-healing time.
- **The first live DePIN triad** — three Trinity Phi/Euler/Gamma chips in a
  cross-die φ-anchor configuration can already emit all three proof types
  (transport, coverage, sensor) at the software-signed level. The compute
  proof requires silicon back.
- **PoC Genesis** — the first 5.8 GHz beacon PoC rounds between neighbours can
  be run locally with no RF emission (digital loopback is already verified).

The bring-up order for the three nodes is described in [`docs/LOCAL_FLASH.md`](docs/LOCAL_FLASH.md).

---

## Metrics (what has been measured)

Every number comes from on-device logs, no hearsay.

| Metric | Value | Source |
|---|---|---|
| M1 static binary size (armv7l musleabihf) | 534 604 B | `smoke/M1_RESULTS.md` |
| M1 binary sha256 | `e5abc335…7290a` | `smoke/M1_RESULTS.md` |
| M1 host tests | 20 unit + 2 integration, RC=0 | `cargo test` |
| Rust `#[test]` blocks in repo | 432 | `grep -rE '^\s*#\[test\]' src tests` |
| Rust source lines | 10 350 | `find src -name '*.rs' \| xargs wc -l` |
| AD9361 tune target | LO 5.8 GHz | `radio/README.md` |
| AD9361 FFT peak (1 MHz tone, digital loopback) | +0.999 MHz | `radio/README.md` |
| AD9361 SNR over noise floor | 108.6 dB (digital loopback only, not over-the-air) | `radio/README.md`; see [W7 finding #5](docs/W7_WEAK_POINTS_STRUCTURAL.md) and [REGULATORY_STATUS](docs/REGULATORY_STATUS.md) |
| AD9361 tuning range | 70 MHz … 6 GHz | `radio/README.md` |
| Sample rate | 30.72 MHz | `radio/README.md` |
| Capture length | 65 536 samples | `radio/README.md` |
| Connected P203 Mini boards | 3 | User confirmation 2026-07-04 |
| T27 spec files ported | 107 | `find specs -name '*.t27' \| wc -l` |

### DePIN tokenomics (contract source, `gHashTag/trinity-contracts`, not yet deployed to mainnet)

| Parameter | Value |
|---|---|
| TRI max supply | 3²⁷ = 7 625 597 484 987 |
| Decimals | 18 |
| Premine | 0% |
| VC allocation | 0% |
| Treasury | 0% |
| Halvings | 9 × 4 years (2026 → 2066) |
| Era 0 (2026-2030) reward | 1000 TRI per proof |
| Era 9 (2062-2066) reward | 1.953125 TRI per proof |
| Anti-flood window | 24 h per chip |
| `MiningPool.claimReward()` checks | 7 (ZK Groth16 BN254 · 2-of-3 chip sigs · unique PUF · φ-anchor 0x47C0 cross-die · BPB ≤ 22393 · anti-flood · not-slashed) |

---

## Local flashing is the current priority

We flash locally, all three `P203 Mini` boards. See [`docs/LOCAL_FLASH.md`](docs/LOCAL_FLASH.md) — a step-by-step checklist:
0. Inventory (three JTAG adapters, three USB-UART cables, three SD cards, a
   Linux PC / workstation, `openocd`, `openFPGALoader`).
1. Boot ARM-Linux (BOOT.BIN + FSBL + kernel + rootfs) on each of the three boards.
2. AD9361 driver up + `iio:device0 name = ad9361` visible on all three.
3. Rebuild `smoke-m1` for `armv7-unknown-linux-musleabihf`, deploy it to all
   three boards, and record three RC=0 results in `smoke/M1_RESULTS.md`.
4. First three-way handshake between the three nodes (M4 dry run).
5. AD9361 5.8 GHz digital loopback confirmed on each of the three (three
   entries in `radio/README.md`).
6. First ternary/PoC beacon between neighbours, locally.

Everything stays in digital loopback. Nothing is radiated over the air until an
external PA+LNA and regulatory clearance are in place.

---

## Build & test (host)

```bash
cargo test              # 20+ unit + 2 integration tests (see Metrics - 110 test blocks in the project)
cargo run --bin smoke-m1
```

## Cross-compile for the Zynq Mini (Cortex-A9, 32-bit ARMv7)

```bash
rustup target add armv7-unknown-linux-musleabihf
cargo build --release --target armv7-unknown-linux-musleabihf
# scp target/armv7-unknown-linux-musleabihf/release/smoke-m1 to the Mini, run on-device,
# append the result to smoke/M1_RESULTS.md
```

More detail in [`docs/LOCAL_FLASH.md`](docs/LOCAL_FLASH.md).

---

## Roadmap (2026 H2 → 2027)

Each stage is stated twice: technically, and as a metaphor.

- **P0 — bring-up** — toolchain, first flash, Mini boots ARM-Linux + AD9361/GPS/PPS; AX7203 sanity.
  "The first wiring, and the board's first breath."
- **P1 — radio + M1 → M3** — AD9361 5.8 GHz + OFDM PHY; `trios-mesh` M1 crypto-on-ARM (already `hw`) → M2 TUN/ETX → M3 iperf3 over 2 hops (bench attenuators).
  "Two nodes hear each other and share one channel."
- **P2 — DEMO GATE (3-node triangle)** — M4 shared uplink over 3-node mesh + M5 self-healing convergence measured. Deliverable: video + metrics + Apache-2.0 + Zenodo DOI. **At the same time, the first dual demo**: mesh-transport + DePIN-node (transport-proof and coverage-proof both live).
  "A triangle that repairs itself."
- **P3 — video-radio + node control (telemetry)** — a single radio channel carries mesh + telemetry + video.
- **P4 — tethered aerial node (elevated relay)** — a node hovering permanently over a point of interest.
- **P5 — free swarm** — a self-organizing swarm with no tether; every node is an operator, and every operator earns TRI.
- **P6 — Trinity silicon (BLOCKED, no route)** — no fabricated die exists, none is scheduled, and the previous route is closed. Until a new route is chosen the on-die BitNet benchmark cannot be run, and the `[Open conjecture]` on the compute-anchor components cannot be closed.
- **P7 — Genesis Day** — mainnet deployment of `trinity-contracts` on Base L2, `EmissionController.renounceOwnership()`, first public proof-of-inference paid in TRI.
- **P8 — Hub71+ AI Cohort 20 (deadline 2026-08-02)** — submitted via `golden-chain-international` (UAE ADGM/DIFC, Armenia as fallback).

## Boards

| Board | Chip | Role |
|---|---|---|
| ALINX AX7203 | Artix-7 `xc7a200t` (IDCODE `0x13636093`) | bench compute + video-radio + 2×GbE mesh (proven on silicon via openXC7 + OpenOCD + AL321) |
| **P201/P203 Mini** × 3 | Zynq-7020 `xc7z020` + AD9361 SDR + GPS/PPS | **flying MVP DePIN node** — M1 crypto `hw`, AD9361 PHY `hw`, three boards connected |

---

## Science base — Trinity papers RU (VAK track)

The scientific corpus the mesh + DePIN stack rests on is published in
[`gHashTag/trinity-papers-ru`](https://github.com/gHashTag/trinity-papers-ru).
The Russian VAK track runs in parallel with the international preprint channel.

| Artefact | Format | Target journal | Category | Roadmap slot |
|---|---|---|---|---|
| GoldenFloat GF16 (arXiv:2606.05017) | LaTeX + PDF (22 pp.) | *Programmirovanie* / Programming and Computer Software (ISP RAS, Pleiades/Springer) | K-1 (Scopus) | basis of the `gf16` module (M2 `-sim`) |
| Catalog of 84 numeric formats | Word (20 pp.) | *Artificial Intelligence and Decision Making* (FRC CSC RAS) | K-1 | basis of the ternary-inference arm |
| *Russia 3.0 - Trinity* (open letter) | Markdown + LaTeX + PDF (12 pp.) | peer-reviewed VAK journal | — | strategic frame for the DePIN rollout |
| GoldenFloat + Setun (Habr) | Markdown + 5 illustrations | Habr | scipop | external narrative |

VAK requirement (2026): at least 2 papers, of which at least one is K-1/K-2 (RCSI "White List" / RSCI / Scopus). Both subject-matter papers above are K-1, so the requirement is met with margin.

Sister repositories: [`gHashTag/t27`](https://github.com/gHashTag/t27), [`gHashTag/goldenfloat-preprint`](https://github.com/gHashTag/goldenfloat-preprint), [`gHashTag/paper3-methodology`](https://github.com/gHashTag/paper3-methodology).

Corpus author: Dmitrii Vasilev · ORCID [0009-0008-4294-6159](https://orcid.org/0009-0008-4294-6159) · admin@t27.ai.

---

## Design notes

- **Directional nonces.** Initiator sends with nonce direction byte `0`, responder `1`,
  so the two TX counters never collide within one session key.
- **Auth before replay.** A frame's tag is verified before the replay window is
  consulted, so forged counters cannot poison the window.
- **Header is authenticated.** The wire header (src/dst/ttl) is passed as AEAD
  associated data — a flipped routing byte fails authentication.
- **No `unsafe`** (`#![forbid(unsafe_code)]`); crypto is RustCrypto + dalek.
- **No chip, no TRI.** Any DePIN-proof path that lets a reward settle without a
  valid Trinity chip signature is a protocol violation, no matter how convenient.

## Related repos

- [`gHashTag/trinity-contracts`](https://github.com/gHashTag/trinity-contracts) — Base L2 mining contracts (TRI, MiningPool, EmissionController, ChipRegistry, JobProver, IGLALedger, BittensorSubnetAttest).
- [`gHashTag/trinity-node`](https://github.com/gHashTag/trinity-node) — DePIN daemon (HAL / Attestation 2-of-3 / Consensus / Miner loop 12 s / Validator 30 s / PoRep / PoC Helium stub / JSON-RPC :9933).
- [`gHashTag/trinity-sdk`](https://github.com/gHashTag/trinity-sdk) — Python API for DePIN AI devs.
- [`gHashTag/trinity-papers-ru`](https://github.com/gHashTag/trinity-papers-ru) — Russian-language versions of the Trinity papers for VAK.
- [`gHashTag/golden-chain-international`](https://github.com/gHashTag/golden-chain-international) — ASCII international edition (UAE ADGM/DIFC, Hub71+ AI Cohort 20).
- [`gHashTag/paper3-methodology`](https://github.com/gHashTag/paper3-methodology) — 84-format numeric catalog.
- [`gHashTag/t27`](https://github.com/gHashTag/t27), [`gHashTag/tt-trinity-phi`](https://github.com/gHashTag/tt-trinity-phi), [`gHashTag/tt-trinity-euler`](https://github.com/gHashTag/tt-trinity-euler), [`gHashTag/tt-trinity-gamma`](https://github.com/gHashTag/tt-trinity-gamma), [`gHashTag/trinity-clara`](https://github.com/gHashTag/trinity-clara).

## Key docs

- [`docs/LOCAL_FLASH.md`](docs/LOCAL_FLASH.md) — step-by-step local flashing of the three boards.
- [`docs/WAVE_DEPIN_2026-07-04.md`](docs/WAVE_DEPIN_2026-07-04.md) — DePIN whitepaper (the four arms, tokenomics, positioning).
- `docs/COMPETITOR_MATRIX_2026-07-04.md` — 10 MANET competitors × 15 fields (in [PR #28](https://github.com/gHashTag/tri-net/pull/28)).
- [`docs/_recon/DEPIN_COMPETITORS_2026-07-04.md`](docs/_recon/DEPIN_COMPETITORS_2026-07-04.md) — 12 DePIN networks × 12 fields.
- [`docs/WAVE_N3_AUDITABILITY_GAP_2026-07-04.md`](docs/WAVE_N3_AUDITABILITY_GAP_2026-07-04.md) — auditability δ paper.
- [`docs/STRENGTHEN.md`](docs/STRENGTHEN.md) — science-driven backlog.
- [`docs/AUTONOMOUS.md`](docs/AUTONOMOUS.md) — human-merge-only policy for agent PRs.

## License

Apache-2.0.

Anchor: **φ² + φ⁻² = 3**.
