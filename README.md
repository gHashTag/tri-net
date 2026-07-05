# tri-net

**TRI-NET drone-mesh + DePIN node** — encrypted, self-routing IP-over-radio on the
P201/P203 **Zynq-7020 Mini**, doubling as a Helium-style DePIN-node with four
supply-side arms (transport / compute / coverage / sensor).
Part of the Trinity Project. Anchor: **φ² + φ⁻² = 3**.

> Naming: this is the **drone-mesh internet-delivery** track plus the DePIN economic
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
| TT SKY26b Trinity silicon (1 GOPS @ 50 MHz @ 1 W) | projected | Tape-out 2026-12-16 |

Every unverified performance number keeps its `-sim` marker. On-device evidence
lives under `smoke/` and `radio/`. All Trinity silicon-anchored DePIN claims
are `[Open conjecture]` until the die comes back — falsification path: run the
BitNet-ternary benchmark on returned silicon, publish the raw log.

---

## Что делает Tri-Net

Одна коробка (`P203 Mini` = Zynq-7020 + AD9361 SDR + GPS/PPS) выполняет две
роли одновременно:

1. **Drone-mesh internet-delivery** — "Starlink без спутников": сеть реле-дронов
   и наземных узлов, разделяющих один uplink через самомаршрутизируемый mesh.
2. **DePIN-узел** (Helium-style + edge compute) — оператор получает TRI-токены
   за реальный вклад в четыре arm'а сети, каждый защищён криптографической
   подписью чипа Trinity.

### Четыре плеча supply-side на одной P203 Mini

| Плечо | Что делает | proof-payload | chip sigs |
|---|---|---|---|
| **Transport** | mesh-relay bandwidth | (from, to, bytes, ts_start, ts_end) | 2-of-3 Phi |
| **Compute** | ternary edge inference (BitNet) | (model_hash, input_hash, output_hash, ops) | 3-of-3 Phi+Euler+Gamma |
| **Coverage** | 5.8 GHz PoC beacon challenge-response | (challenger, responder, witness, rssi, tof) | 3-of-3 cross-die φ |
| **Sensor** | RF spectrum atlas + GPS-jam detection | (snapshot_hash, gps_time, location_hash) | 1-of-3 any |

Все четыре плеча оседают в один и тот же `MiningPool.claimReward()` — семь
проверок, ни одна не обходится. Полное описание — `docs/WAVE_DEPIN_2026-07-04.md`.

---

## Три сетевые карты как база сети

Три `P203 Mini` собраны, запитаны и уже пропускают через себя проверенные
криптоданные (см. `smoke/M1_RESULTS.md`). Это минимальная база для:

- **P2 DEMO GATE** (M4 + M5) — три-узловой треугольник, один общий uplink,
  измеримое время самовосстановления mesh.
- **Первый живой DePIN triad** — три чипа Trinity Phi/Euler/Gamma в
  cross-die φ-anchor конфигурации могут выдавать все три типа proof'ов
  (transport, coverage, sensor) уже сейчас на software-signed level. Compute
  proof требует silicon back.
- **PoC Genesis** — первые PoC-раунды 5.8 GHz beacon between-neighbors
  можно гонять локально без RF-выхода в эфир (digital loopback уже
  верифицирован).

Порядок разворачивания трёх узлов описан в [`docs/LOCAL_FLASH.md`](docs/LOCAL_FLASH.md).

---

## Metrics (что уже измерено)

Все числа — с on-device логов, без hearsay.

| Метрика | Значение | Источник |
|---|---|---|
| M1 static binary size (armv7l musleabihf) | 534 604 B | `smoke/M1_RESULTS.md` |
| M1 binary sha256 | `e5abc335…7290a` | `smoke/M1_RESULTS.md` |
| M1 host tests | 20 unit + 2 integration, RC=0 | `cargo test` |
| Rust `#[test]` blocks in repo | 110 | `grep -rE '^\s*#\[test\]' src tests` |
| Rust source lines | 4 463 | `find src -name '*.rs' \| xargs wc -l` |
| AD9361 tune target | LO 5.8 GHz | `radio/README.md` |
| AD9361 FFT peak (1 MHz tone, digital loopback) | +0.999 MHz | `radio/README.md` |
| AD9361 SNR over noise floor | 108.6 dB (digital loopback only, not over-the-air) | `radio/README.md`; see [W7 finding #5](docs/W7_WEAK_POINTS_STRUCTURAL.md#находка-5) and [REGULATORY_STATUS](docs/REGULATORY_STATUS.md) |
| AD9361 tuning range | 70 MHz … 6 GHz | `radio/README.md` |
| Sample rate | 30.72 MHz | `radio/README.md` |
| Capture length | 65 536 samples | `radio/README.md` |
| Connected P203 Mini boards | 3 | User confirmation 2026-07-04 |
| T27 spec files ported | 1 (`specs/wire.t27`) | `find specs -name '*.t27'` |

### DePIN tokenomics (contract source, `gHashTag/trinity-contracts`, not yet deployed to mainnet)

| Параметр | Значение |
|---|---|
| TRI max supply | 3²⁷ = 7 625 597 484 987 |
| Decimals | 18 |
| Premine | 0% |
| VC allocation | 0% |
| Treasury | 0% |
| Halvings | 9 × 4 года (2026 → 2066) |
| Era 0 (2026-2030) reward | 1000 TRI per proof |
| Era 9 (2062-2066) reward | 1.953125 TRI per proof |
| Anti-flood window | 24 h per chip |
| `MiningPool.claimReward()` checks | 7 (ZK Groth16 BN254 · 2-of-3 chip sigs · unique PUF · φ-anchor 0x47C0 cross-die · BPB ≤ 22393 · anti-flood · not-slashed) |

---

## Локальная прошивка сейчас — приоритет

Мы прошиваем локально, все три `P203 Mini`. См. [`docs/LOCAL_FLASH.md`](docs/LOCAL_FLASH.md) — пошаговый чек-лист:
0. Инвентаризация (три JTAG-адаптера, три USB-UART, три SD-карты, PC/линуксовая
   рабочая станция, `openocd`, `openFPGALoader`).
1. Boot ARM-Linux (BOOT.BIN + FSBL + kernel + rootfs) на каждой из трёх плат.
2. AD9361 driver up + `iio:device0 name = ad9361` виден на всех трёх.
3. Пересобрать `smoke-m1` под `armv7-unknown-linux-musleabihf`, залить на все
   три платы, зафиксировать три RC=0 в `smoke/M1_RESULTS.md`.
4. Первый three-way handshake между тремя узлами (M4 dry-run).
5. AD9361 5.8 GHz digital loopback подтверждён на каждой из трёх (три записи
   в `radio/README.md`).
6. Первый ternary/PoC-beacon between-neighbors локально.

Всё в digital loopback, никакого излучения в эфир до внешнего PA+LNA + разрешения.

---

## Build & test (host)

```bash
cargo test              # 20+ unit + 2 integration tests (см. Metrics — 110 test blocks в проекте)
cargo run --bin smoke-m1
```

## Cross-compile for the Zynq Mini (Cortex-A9, 32-bit ARMv7)

```bash
rustup target add armv7-unknown-linux-musleabihf
cargo build --release --target armv7-unknown-linux-musleabihf
# scp target/armv7-unknown-linux-musleabihf/release/smoke-m1 to the Mini, run on-device,
# append the result to smoke/M1_RESULTS.md
```

Подробнее — [`docs/LOCAL_FLASH.md`](docs/LOCAL_FLASH.md).

---

## Roadmap (2026 H2 → 2027)

Каждый этап заявляется на английском (technical) и по-русски (метафора).

- **P0 — bring-up** — toolchain, first flash, Mini boots ARM-Linux + AD9361/GPS/PPS; AX7203 sanity.
  «Первая проводка и первое дыхание платы.»
- **P1 — radio + M1 → M3** — AD9361 5.8 GHz + OFDM PHY; `trios-mesh` M1 crypto-on-ARM (уже `hw`) → M2 TUN/ETX → M3 iperf3 over 2 hops (bench attenuators).
  «Два дрона слышат друг друга и делятся одним каналом.»
- **P2 — DEMO GATE (3-node triangle)** — M4 shared uplink over 3-node mesh + M5 self-healing convergence measured. Deliverable: video + metrics + Apache-2.0 + Zenodo DOI. **Одновременно — первый двойной demo**: mesh-transport + DePIN-node (transport-proof + coverage-proof живые).
  «Треугольник, который сам себя чинит.»
- **P3 — video-radio + drone C2 (MAVLink)** — один радиоканал несёт mesh + телеметрию + видео.
- **P4 — tethered drone (Flying-COW analog)** — постоянно висящий узел над точкой интереса.
- **P5 — свободный swarm** — self-organizing swarm без tether'а, каждый узел это operator, каждый operator получает TRI.
- **P6 — Trinity silicon back** — tape-out 2026-12-16 → returned silicon → BitNet benchmark на кристалле → `[Open conjecture]` компонентов compute-anchor'а закрывается.
- **P7 — Genesis Day** — mainnet deployment `trinity-contracts` на Base L2, `EmissionController.renounceOwnership()`, первый public proof-of-inference за TRI.
- **P8 — Hub71+ AI Cohort 20 (deadline 2026-08-02)** — подача через `golden-chain-international` (UAE ADGM/DIFC, Армения-резерв).

## Boards

| Board | Chip | Role |
|---|---|---|
| ALINX AX7203 | Artix-7 `xc7a200t` (IDCODE `0x13636093`) | bench compute + video-radio + 2×GbE mesh (proven on silicon via openXC7 + OpenOCD + AL321) |
| **P201/P203 Mini** × 3 | Zynq-7020 `xc7z020` + AD9361 SDR + GPS/PPS | **flying MVP DePIN node** — M1 crypto `hw`, AD9361 PHY `hw`, three boards connected |

---

## Science base — Trinity papers RU (ВАК track)

Научный корпус, на который опирается mesh + DePIN-стек, публикуется в
[`gHashTag/trinity-papers-ru`](https://github.com/gHashTag/trinity-papers-ru).
Российский трек ВАК ведётся параллельно с международным препринт-каналом.

| Артефакт | Формат | Целевой журнал | Категория | Roadmap-slot |
|---|---|---|---|---|
| GoldenFloat GF16 (arXiv:2606.05017) | LaTeX + PDF (22 стр.) | «Программирование» / Programming and Computer Software (ИСП РАН, Pleiades/Springer) | К-1 (Scopus) | базис `gf16` модуля (M2 `-sim`) |
| Каталог 84 численных форматов | Word (20 стр.) | «Искусственный интеллект и принятие решений» (ФИЦ ИУ РАН) | К-1 | базис ternary-inference плеча |
| «Россия 3.0 — Троица» (открытое обращение) | Markdown + LaTeX + PDF (12 стр.) | рецензируемый журнал ВАК | — | стратегическая рамка DePIN-развёртывания |
| GoldenFloat + Сетунь (Habr) | Markdown + 5 иллюстраций | Habr | scipop | внешний нарратив |

Требование ВАК (2026): ≥ 2 статьи, минимум одна К-1/К-2 («Белый список» РЦНИ / RSCI / Scopus). Обе профильные статьи выше — К-1, требование закрывается с запасом.

Sister-репозитории: [`gHashTag/t27`](https://github.com/gHashTag/t27), [`gHashTag/goldenfloat-preprint`](https://github.com/gHashTag/goldenfloat-preprint), [`gHashTag/paper3-methodology`](https://github.com/gHashTag/paper3-methodology).

Автор корпуса: Дмитрий Васильев · ORCID [0009-0008-4294-6159](https://orcid.org/0009-0008-4294-6159) · admin@t27.ai.

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
- [`gHashTag/trinity-sdk`](https://github.com/gHashTag/trinity-sdk) — Python API для DePIN AI devs.
- [`gHashTag/trinity-papers-ru`](https://github.com/gHashTag/trinity-papers-ru) — русские версии Trinity-статей для ВАК.
- [`gHashTag/golden-chain-international`](https://github.com/gHashTag/golden-chain-international) — ASCII international edition (UAE ADGM/DIFC, Hub71+ AI Cohort 20).
- [`gHashTag/paper3-methodology`](https://github.com/gHashTag/paper3-methodology) — 84-format numeric catalog.
- [`gHashTag/t27`](https://github.com/gHashTag/t27), [`gHashTag/tt-trinity-phi`](https://github.com/gHashTag/tt-trinity-phi), [`gHashTag/tt-trinity-euler`](https://github.com/gHashTag/tt-trinity-euler), [`gHashTag/tt-trinity-gamma`](https://github.com/gHashTag/tt-trinity-gamma), [`gHashTag/trinity-clara`](https://github.com/gHashTag/trinity-clara).

## Key docs

- [`docs/LOCAL_FLASH.md`](docs/LOCAL_FLASH.md) — пошаговая локальная прошивка трёх плат.
- [`docs/WAVE_DEPIN_2026-07-04.md`](docs/WAVE_DEPIN_2026-07-04.md) — DePIN whitepaper (четыре плеча, tokenomics, positioning).
- `docs/COMPETITOR_MATRIX_2026-07-04.md` — 10 MANET-конкурентов × 15 полей (в [PR #28](https://github.com/gHashTag/tri-net/pull/28)).
- [`docs/_recon/DEPIN_COMPETITORS_2026-07-04.md`](docs/_recon/DEPIN_COMPETITORS_2026-07-04.md) — 12 DePIN-сетей × 12 полей.
- [`docs/WAVE_N3_AUDITABILITY_GAP_2026-07-04.md`](docs/WAVE_N3_AUDITABILITY_GAP_2026-07-04.md) — auditability δ paper.
- [`docs/STRENGTHEN.md`](docs/STRENGTHEN.md) — science-driven backlog.
- [`docs/AUTONOMOUS.md`](docs/AUTONOMOUS.md) — human-merge only policy для agent PR's.

## License

Apache-2.0.

Anchor: **φ² + φ⁻² = 3**.
