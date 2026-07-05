# M2-M4 hardware + FPGA-attestation parallel track — decomposed plan

> phi^2 + phi^-2 = 3

**Дата**: 2026-07-05. **Автор**: Perplexity Computer (cloud, sandbox). **Скоуп**: план на следующий Wave-луп с двумя параллельными треками. **Основано на**: [WAVE_REPORT_2026-07-05_FULL.md](WAVE_REPORT_2026-07-05_FULL.md), [W7_WEAK_POINTS_STRUCTURAL.md](W7_WEAK_POINTS_STRUCTURAL.md).

---

## 0. Одно предложение стратегии

Разгоняем M2→M3→M4 real-network smoke на трёх P203 Mini через image-bake unlock, параллельно открываем **FPGA-attestation** трек как interim identity-source, чтобы Compute-arm экономики не висел на tape-out'е 2026-12-16.

**Что это не есть**: не отказ от silicon SKY26b. Silicon остаётся financial anchor и proof-of-work substrate. FPGA-anchor — interim (уровень 3 по собственной шкале M7 из BENCHMARK_VS_MANET) на 6-12 месяцев до кремния.

---

## 1. Два трека, шесть треугольников — что мы разгоняем

```
Track A (hardware pipeline):        Track B (FPGA-attestation):
  M2 TUN/IP smoke                     A1 FPGA identity survey
  M3 iperf3 over 2 hops               A2 device-DNA + eFUSE hookup
  M4 triangle P2 DEMO GATE            A3 bitstream attestation POC
                                      A4 PUF measurement
  (M5 self-heal — deferred            A5 «Proof of FPGA» whitepaper draft
   until 4+ nodes)
```

Оба трека независимы по инструментам, зависимы по железу (одни и те же три Zynq-7020 board'а). Планирование — так, чтобы Track A использовал PS (ARM Linux) а Track B использовал PL (FPGA fabric), одновременно на одной коробке. Это возможно потому, что Zynq-7020 — heterogeneous, PS и PL — отдельные ресурсы.

---

## 2. Track A — Hardware pipeline (M2 → M3 → M4)

### 2.1 Blocker chain, что снимает что

```
image-bake milestone  ─┬─► M2 TUN/IP real-network smoke
                       │        │
                       │        └─► M3 iperf3 over 2 hops
                       │                 │
                       │                 └─► M4 triangle P2 DEMO GATE
                       │
                       └─► Track B тоже разблокируется
                           (нужны persistent SSH + Vivado bitstream deployment)
```

**Ключ**: image-bake — общий blocker обоих треков. Пока не сделан — оба стоят.

### 2.2 M2 — real-network smoke (~7-10 дней)

**Definition of done**: три board'а с уникальной identity, TUN device up, HELLO discovery видит соседей, ETX table сходится, PING работает по IP через mesh.

**Sub-tasks**:

| # | Задача | Кто | Blocker |
|---|---|---|---|
| M2.0 | Image-bake — Petalinux или buildroot rootfs с persistent identity | Human + local agent | JTAG + Vivado на macOS |
| M2.1 | Flash procedure — три уникальные SD-card image, unique MAC/hostname/IP | Human | M2.0 |
| M2.2 | `daemon.rs` boot script — systemd unit для `mesh-daemon` | Cloud agent | ничего |
| M2.3 | TUN device setup — `/dev/net/tun`, `10.42.0.X/24`, `ip route add` | Cloud agent | M2.1 (unique IP) |
| M2.4 | HELLO discovery on-device smoke — 3 board'а видят друг друга | Human + cloud logs | M2.3 × 3 |
| M2.5 | ETX table convergence — deterministic pick после 10 HELLO rounds | Cloud agent (test harness) | M2.4 |
| M2.6 | PING through mesh — `ping 10.42.0.2` from board-1 | Human | M2.5 |
| M2.7 | M2_RESULTS.md — sha256 логов, wireshark capture, cross-env verified | Cloud agent | M2.6 |

**Sandbox constraint**: cloud agent не имеет доступа к JTAG/USB — все hardware ops требуют human. Cloud agent может писать код (M2.2-M2.5 kernels), test harnesses (M2.5-M2.7), документацию (M2.7).

**Timeline**: 7-10 дней при 2ч/день от human'а на flash/smoke, cloud agent параллельно.

### 2.3 M3 — iperf3 over 2 hops (~3-5 дней)

**Definition of done**: iperf3 TCP throughput measurement between board-1 and board-3, где board-2 — единственный relay. Число cited to source.

**Sub-tasks**:

| # | Задача | Blocker |
|---|---|---|
| M3.1 | RF loopback bench — SMA-кабель + attenuator (30-50 dB) вместо антенн | M2.6 |
| M3.2 | iperf3 install on all 3 boards (armv7l static) | M2.0 |
| M3.3 | Baseline 1-hop: board-1 ↔ board-2 iperf3 TCP | M3.1 |
| M3.4 | 2-hop: board-1 ↔ board-3 через board-2 relay | M3.3 |
| M3.5 | M3_RESULTS.md — throughput, RTT, PDR числа с cross-env replay | M3.4 |

**Регуляторный контекст**: RF loopback через SMA — closed loop, ничего не излучается. Тестируемо без FCC/NBTC (Thailand) approval. Это уже запланировано в [`docs/LOCAL_FLASH.md`](LOCAL_FLASH.md) §9.3.

### 2.4 M4 — triangle P2 DEMO GATE (~5-7 дней)

**Definition of done**: три board'а активны одновременно (не пары), traffic течёт board-1 → board-2 → board-3 → board-1 замкнутое кольцо, все три ETX table в consistent state.

**Sub-tasks**: M4.1-M4.6 — аналогично M3, но с 3-way topology.

**⚠️ Важно per W7_WEAK_POINTS_STRUCTURAL.md находка 3**: 3-node triangle НЕ демонстрирует self-heal в интересном смысле — при отказе одного узла остаются 2 в линии, single route. **Rename**: «M4 triangle P2 DEMO GATE» → **«M4 3-node convergence GATE»**. Не заявляем self-heal в публичной коммуникации на 3 узлах. Self-heal claim откладываем до **M6 — 4-5 node topology** (deferred, отдельный board procurement).

### 2.5 M5 — self-heal — DEFERRED

Причина: 3 узла недостаточно для path-diversity choice (W7 finding #3). Оставляем в roadmap, но переносим на M6 (4-5 nodes). До тех пор self-heal claim — только software-simulated.

---

## 3. Track B — «Proof of FPGA» attestation (параллельный, независимый от M2-M4 по коду)

### 3.1 Мотивация в трёх пунктах

1. **W7 finding #1**: silicon slip risk 3/6/12 месяцев. Нужен interim identity-anchor.
2. **W7 finding #2**: Compute-arm заблокирован полностью до silicon. Нужен fallback.
3. **W7 finding #7**: экономика уязвима без Compute-arm 24+ недель. Нужен revenue path pre-silicon.

**Гипотеза**: Zynq-7020 PL fabric (уже стоит на каждой board'е, ничем не занят) может быть привязан к node identity через:
- **Device DNA** — 57-bit unique per die, read-only (Xilinx UG470 §32)
- **eFUSE** — 32-bit user-programmable, non-volatile
- **Bitstream hash** — SHA256 от загружаемого bitstream, засвидетельствованный boot-loader'ом
- **PUF** (ring-oscillator или SRAM) — physically unclonable function из FPGA logic

Все четыре — **уровень 3 по собственной шкале M7** (не силикон, но hardware-anchored и не reproducible на software). Это заведомо слабее custom ASIC (уровень 5), но заведомо сильнее pure software (уровень 1).

### 3.2 Sub-tasks (independent of M2-M4)

**A1 FPGA identity survey (~3 дня)**:
- A1.1 Read Xilinx UG470 §32 — device DNA API
- A1.2 Read Xilinx eFUSE app-notes (XAPP1246 или ekvivалент)
- A1.3 Survey academic PUF literature (см. `docs/W7_FPGA_LITERATURE.md`)
- A1.4 Deliverable: `docs/FPGA_IDENTITY_SURVEY.md`

**A2 Device-DNA + eFUSE hookup (~5 дней)**:
- A2.1 Vivado project — минимальный bitstream, читающий device DNA через AXI-Lite
- A2.2 Rust userspace tool `fpga-identity` на board — `read_dna()` возвращает 57-bit
- A2.3 Test — три board'а дают три уникальных DNA (verify uniqueness)
- A2.4 Deliverable: `smoke/FPGA_DNA_3BOARDS.md` — три sha256(dna) числа

**A3 Bitstream attestation POC (~7 дней)**:
- A3.1 Signed bitstream — Vivado + Xilinx `bitstream` tool с sha256 
- A3.2 Boot-time check — U-Boot читает bitstream, hashes it, compares to eFUSE-stored expected_hash
- A3.3 Runtime attestation API — `fpga-attest --challenge <nonce>` returns `(dna, bitstream_hash, sig)` signed by device-DNA-derived key
- A3.4 Deliverable: `docs/FPGA_ATTESTATION_POC.md`

**A4 PUF measurement (~10 дней)**:
- A4.1 Ring-oscillator PUF design (открытая литература, ~100-1000 ROs)
- A4.2 Enroll — на каждой из 3 board'ов измерить PUF response, записать в secure DB
- A4.3 Verify — повторить измерения, посчитать intra-device stability (Hamming distance)
- A4.4 Uniqueness — сравнить responses across 3 boards, посчитать inter-device HD (target ~50%)
- A4.5 Deliverable: `docs/FPGA_PUF_MEASUREMENT.md` с числами

**A5 «Proof of FPGA» whitepaper draft (~5 дней)**:
- A5.1 Objective: связать A1-A4 в один attestation protocol для DePIN
- A5.2 Compare to Helium PoC beacon (Coverage arm аналог)
- A5.3 Compare to Bittensor/Akash compute attestation
- A5.4 Threat model — что защищает, что не защищает
- A5.5 Deliverable: `docs/PROOF_OF_FPGA_v0.md` (arXiv-ready draft)

**Total Track B**: ~30 дней при full-time, ~60 дней при 2ч/день параллельно с Track A.

### 3.3 Monetization vectors (ответ на пользовательский вопрос «на этом можно зарабатывать?»)

**Три канала**, если Proof of FPGA работает:

1. **Interim TRI-emission**: Era-0 rewards для Transport/Coverage/Sensor arms усиливаются FPGA-attestation вместо software-signed. Sybil resistance повышается (нельзя виртуализировать physical FPGA), rewards легитимно платить до silicon.

2. **FPGA-attestation-as-a-Service**: другие DePIN проекты покупают наш attestation stack (Helium-like, Akash, IoTeX, DIMO) — bitstream + attestation SDK + verifier. Цена per-node license, аналог Intrinsic ID / PUFsecurity бизнеса.

3. **Academic/grant-track**: Proof of FPGA как публикуемая concept (если ещё не опубликована — см. `docs/W7_FPGA_LITERATURE.md` §5, TL;DR ответ 1). Даёт цитируемость и увеличивает шансы Hub71+ (submission 2026-08-02), NSF, EU Horizon.

**Reality-check от W7 finding #7**: 0% premine/treasury означает, что монетизация #2 требует внешнего юр. канала (LLC + license contracts), которого пока нет. Монетизация #1 — внутренний механизм, no external structure needed. Монетизация #3 — bootstrap-friendly (грант — легитимный источник капитала без нарушения tokenomics).

---

## 4. Общие blocker'ы и зависимости

```
image-bake ──────► M2 ──► M3 ──► M4
      │
      └───► FPGA bitstream deployment ──► A2 ──► A3 ──► A4 ──► A5
                                                                │
                              A1 survey (no blocker) ───────────┘
```

**Single critical path node**: image-bake. Всё остальное — параллельно или downstream.

**Sandbox capability boundary**:
| Sub-task | Cloud agent | Human required |
|---|---|---|
| M2.0 image-bake | Petalinux script + doc | JTAG flash |
| M2.2 daemon.rs code | ✅ full | ❌ |
| M2.3 TUN userspace | ✅ full | ❌ |
| M2.4 HELLO smoke | code, run harness | log capture on-device |
| M3.1 RF loopback | doc procedure | SMA + attenuator + physical setup |
| M4.x triangle | code + test | 3 boards flashed + power |
| A1 survey | ✅ full | ❌ |
| A2 Vivado project | .tcl script | Vivado run + JTAG |
| A3 attestation code | ✅ full | Vivado bitstream build |
| A4 PUF Vivado | RO PUF design + Rust reader | Vivado + JTAG |

Cloud agent покрывает ~70% работы. Human — hardware ops + Vivado + merge.

---

## 5. Timeline (реалистичный)

Assumption: 2ч/день от human'а, 8ч/день от cloud agent'а.

| Week | Track A milestone | Track B milestone |
|---|---|---|
| W8 (2026-07-06→07-12) | image-bake начат, M2.0-M2.2 | A1 survey done, A2 planning |
| W9 | M2.3-M2.5 | A2 Vivado project done |
| W10 | M2.6-M2.7 (M2 hw ✅) | A2 verify uniqueness |
| W11 | M3.1-M3.3 (1-hop iperf3) | A3 attestation POC start |
| W12 | M3.4-M3.5 (M3 hw ✅) | A3 POC finish |
| W13 | M4.1-M4.6 (M4 hw ✅) | A4 PUF start |
| W14 | Track A wrap + M2/M3/M4 paper section | A4 PUF finish |
| W15-W16 | Buffer / M6 planning (4-5 nodes) | A5 whitepaper draft |

**Full timeline**: ~10 недель до Track A + Track B оба в `hw` state. Это до **2026-09-15**, за 3 месяца до silicon tape-out. Хорошо — Proof of FPGA publish/monetization в parallel с silicon bring-up.

---

## 6. Ratcheting rules — что нельзя откатить

Три жёстких инварианта:

1. **spec-drift-guard CI не обходить**. Любой M2 patch в `wire.rs` regenerated из `specs/wire.t27` через `t27c`. CI fails на drift.
2. **No pre-silicon Trinity claim без tag**. Compute-arm software fallback помечен явно `[software-signed pre-silicon]`, не `[chip-sig]`.
3. **No self-heal claim на 3 nodes**. Renamed M4 → «convergence GATE», не «self-heal DEMO».

---

## 7. Kill-switches (когда откатывать)

- **Track A kill-switch**: если image-bake milestone не сходится за 3 недели (target 2026-07-27) — remote pair-programming session с внешним embedded engineer (Nova Labs alumni, Xilinx forums, Puzhi vendor support).
- **Track B kill-switch**: если A4 PUF intra-device HD > 15% (нестабильный) — pivot на pure device-DNA + eFUSE (без PUF), сохранив A2+A3. Не убивает трек.
- **Silicon slip kill-switch** (per W7 finding #1): если tape-out 2026-12-16 slips > 3 месяца — extend Track B roadmap ещё на 3 месяца, formally publish Proof of FPGA v1 as long-term Compute-arm substitute (не только interim).

---

## 8. Первый шаг — что делаем сегодня

Задача 5 из недельного todo. Сегодня из sandbox я могу:

1. Написать `daemon.rs` boot-script (M2.2) — код готов быть смерженным после image-bake.
2. Дописать M2 pure-logic tests на UDP transport wrapper (сейчас есть только TUN allocation и wire boundaries; UDP-wrapper тестов нет — можно добавить)
3. Написать shell-скрипт `scripts/m2/three-board-smoke.sh` который запустится на flashed board'ах и соберёт evidence в `smoke/M2_RESULTS.md`
4. Draft PR с этими тремя артефактами, `feat/m2-daemon-scaffolding` branch, `documentation,m2` label, DRAFT-only.

**Realistic**: cloud agent доводит M2 code-side до готовности, human делает image-bake на своей стороне, они встречаются на M2.4 (HELLO discovery smoke). Аналогично для Track B — cloud agent готовит A1 survey и Vivado .tcl scripts, human запускает Vivado.

---

## 9. Что записано на будущее (W8-W16 backlog)

- CONTRIBUTING.md (W7 finding #8): написать 15-минутный quick-start для human contributor.
- SILICON_SLIP_CONTINGENCY.md (W7 finding #1): три сценария — slip 3/6/12 месяцев с явными датами и последствиями.
- REGULATORY_STATUS.md (W7 finding #6): консолидация всех регуляторных знаний в один документ рядом с README.
- SUBSIDY_PROGRAM.md (W7 finding #7): first-N-operators bootstrap program без нарушения 0% premine.
- Merge-права delegation (W7 finding #8): docs-only PR merge для второго доверенного человека.

---

phi^2 + phi^-2 = 3
