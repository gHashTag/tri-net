# tri-net

**TRI-NET mesh + DePIN node** - шифрованный самомаршрутизируемый IP-over-radio на
P201/P203 **Zynq-7020 Mini**, одновременно работающий DePIN-узлом в стиле Helium с
четырьмя supply-side плечами (transport / compute / coverage / sensor).
Часть Trinity Project. Anchor: **φ² + φ⁻² = 3**.

> 🌍 **Гражданская связь.** tri-net создаётся для мирного, гражданского применения - доступ в интернет в сельских и удалённых районах, связь при ликвидации последствий бедствий и mesh-сети, принадлежащие сообществам. Открытый исходный код, шифрование, самовосстановление.


> О названии: это трек **mesh internet-delivery** плюс экономический слой DePIN
> поверх него. Не путать с работой над silicon-узлом "TRI-NET" для троичных
> вычислений в `gHashTag/trinity`, `gHashTag/tt-trinity-*`.

---

## Статус (2026-07-04)

| Слой | Состояние | Подтверждение |
|---|---|---|
| M1 crypto на ARM (X25519 + ChaCha20-Poly1305) | **hw** ✅ | `smoke/M1_RESULTS.md` - статический бинарник armv7l 534 604 B, sha256 `e5abc335…7290a`, RC=0, 2026-07-01 |
| AD9361 5.8 GHz PHY digital loopback | **hw** ✅ | `radio/README.md` - LO 5.8 GHz, пик FFT +0.999 MHz, SNR 108.6 dB, 2026-07-01 |
| Три платы P201/P203 Mini физически соединены | **hw** ✅ | Подтверждение пользователя 2026-07-04 |
| M2 маршрутизация TUN/IP (ETX + discovery) | `-sim` | Rust unit-тесты, запуска на устройстве не было |
| M3 iperf3 через 2 хопа (стендовые аттенюаторы) | `-sim` | Не запускалось |
| M4 треугольник из 3 узлов, общий uplink (P2 DEMO GATE) | `-sim` | Не запускалось |
| M5 измеренная сходимость самовосстановления | undefined | B11 не влит |
| Развёртывание trinity-contracts (Base L2) | Sepolia only | Mainnet Genesis Day не достигнут |
| Trinity silicon (1 GOPS @ 50 MHz @ 1 W) | NO ROUTE | кристалла не существует, изготовление не запланировано; прежний shuttle-маршрут закрыт |

Каждое непроверенное значение производительности сохраняет свой маркер `-sim`.
Подтверждения с устройств лежат в `smoke/` и `radio/`. Все DePIN-утверждения,
опирающиеся на Trinity silicon, имеют статус `[Open conjecture]` до возврата
кристалла - путь опровержения: запустить BitNet-ternary benchmark на вернувшемся
кристалле, опубликовать сырой лог.

---

## Что делает Tri-Net

Одна коробка (`P203 Mini` = Zynq-7020 + AD9361 SDR + GPS/PPS) выполняет две
роли одновременно:

1. **Mesh internet-delivery** - "Starlink без спутников": сеть мобильных реле
   и наземных узлов, разделяющих один uplink через самомаршрутизируемый mesh.
2. **DePIN-узел** (Helium-style + edge compute) - оператор получает TRI-токены
   за реальный вклад в четыре arm'а сети, каждый защищён криптографической
   подписью чипа Trinity.

### Четыре плеча supply-side на одной P203 Mini

| Плечо | Что делает | proof-payload | chip sigs |
|---|---|---|---|
| **Transport** | пропускная способность mesh-relay | (from, to, bytes, ts_start, ts_end) | 2-of-3 Phi |
| **Compute** | троичный edge-inference (BitNet) | (model_hash, input_hash, output_hash, ops) | 3-of-3 Phi+Euler+Gamma |
| **Coverage** | challenge-response PoC-beacon на 5.8 GHz | (challenger, responder, witness, rssi, tof) | 3-of-3 cross-die φ |
| **Sensor** | атлас RF-спектра + детекция GPS-jamming | (snapshot_hash, gps_time, location_hash) | 1-of-3 any |

Все четыре плеча оседают в один и тот же `MiningPool.claimReward()` - семь
проверок, ни одна не обходится. Полное описание - `docs/WAVE_DEPIN_2026-07-04.md`.

---

## Три сетевые карты как база сети

Три `P203 Mini` собраны, запитаны и уже пропускают через себя проверенные
криптоданные (см. `smoke/M1_RESULTS.md`). Это минимальная база для:

- **P2 DEMO GATE** (M4 + M5) - три-узловой треугольник, один общий uplink,
  измеримое время самовосстановления mesh.
- **Первый живой DePIN triad** - три чипа Trinity Phi/Euler/Gamma в
  cross-die φ-anchor конфигурации могут выдавать все три типа proof'ов
  (transport, coverage, sensor) уже сейчас на software-signed level. Compute
  proof требует silicon back.
- **PoC Genesis** - первые PoC-раунды 5.8 GHz beacon between-neighbors
  можно гонять локально без RF-выхода в эфир (digital loopback уже
  верифицирован).

Порядок разворачивания трёх узлов описан в [`docs/LOCAL_FLASH.md`](docs/LOCAL_FLASH.md).

---

## Метрики (что уже измерено)

Все числа - с on-device логов, без hearsay.

| Метрика | Значение | Источник |
|---|---|---|
| Размер статического бинарника M1 (armv7l musleabihf) | 534 604 B | `smoke/M1_RESULTS.md` |
| sha256 бинарника M1 | `e5abc335…7290a` | `smoke/M1_RESULTS.md` |
| Тесты M1 на хосте | 20 unit + 2 integration, RC=0 | `cargo test` |
| Блоков Rust `#[test]` в репозитории | 432 (пересчитано 2026-08-19) | `tri facts` |
| Строк исходного кода на Rust | считается командой, не хранится здесь | `tri facts` | xargs wc -l` |
| Целевая настройка AD9361 | LO 5.8 GHz | `radio/README.md` |
| Пик FFT AD9361 (тон 1 MHz, digital loopback) | +0.999 MHz | `radio/README.md` |
| SNR AD9361 над уровнем шума | 108.6 dB (только digital loopback, не в эфире) | `radio/README.md`; см. [находка W7 #5](docs/W7_WEAK_POINTS_STRUCTURAL.md#находка-5) и [REGULATORY_STATUS](docs/REGULATORY_STATUS.md) |
| Диапазон настройки AD9361 | 70 MHz … 6 GHz | `radio/README.md` |
| Частота дискретизации | 30.72 MHz | `radio/README.md` |
| Длина захвата | 65 536 сэмплов | `radio/README.md` |
| Подключённых плат P203 Mini | 3 | Подтверждение пользователя 2026-07-04 |
| Портировано spec-файлов T27 | 107 (пересчитано 2026-08-19) | `tri facts` |

### DePIN tokenomics (исходники контрактов, `gHashTag/trinity-contracts`, в mainnet ещё не развёрнуто)

| Параметр | Значение |
|---|---|
| Максимальная эмиссия TRI | 3²⁷ = 7 625 597 484 987 |
| Decimals | 18 |
| Premine | 0% |
| Аллокация VC | 0% |
| Treasury | 0% |
| Halving'ов | 9 × 4 года (2026 → 2066) |
| Награда эры 0 (2026-2030) | 1000 TRI за proof |
| Награда эры 9 (2062-2066) | 1.953125 TRI за proof |
| Anti-flood окно | 24 h на чип |
| Проверок в `MiningPool.claimReward()` | 7 (ZK Groth16 BN254 · 2-of-3 chip sigs · уникальный PUF · φ-anchor 0x47C0 cross-die · BPB ≤ 22393 · anti-flood · not-slashed) |

---

## Локальная прошивка сейчас - приоритет

Мы прошиваем локально, все три `P203 Mini`. См. [`docs/LOCAL_FLASH.md`](docs/LOCAL_FLASH.md) - пошаговый чек-лист:
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

## Сборка и тесты (на хосте)

```bash
cargo test              # 20+ unit + 2 integration тестов (см. Метрики - 118 test-блоков в проекте)
cargo run --bin smoke-m1
```

## Кросс-компиляция под Zynq Mini (Cortex-A9, 32-bit ARMv7)

```bash
rustup target add armv7-unknown-linux-musleabihf
cargo build --release --target armv7-unknown-linux-musleabihf
# scp target/armv7-unknown-linux-musleabihf/release/smoke-m1 на Mini, запустить на устройстве,
# дописать результат в smoke/M1_RESULTS.md
```

Подробнее - [`docs/LOCAL_FLASH.md`](docs/LOCAL_FLASH.md).

---

## Roadmap (2026 H2 → 2027)

Каждый этап заявляется технически и метафорой.

- **P0 - bring-up** - toolchain, первая прошивка, Mini загружает ARM-Linux + AD9361/GPS/PPS; проверка работоспособности AX7203.
  «Первая проводка и первое дыхание платы.»
- **P1 - radio + M1 → M3** - AD9361 5.8 GHz + OFDM PHY; `trios-mesh` M1 crypto-on-ARM (уже `hw`) → M2 TUN/ETX → M3 iperf3 через 2 хопа (стендовые аттенюаторы).
  «Два узла слышат друг друга и делятся одним каналом.»
- **P2 - DEMO GATE (треугольник из 3 узлов)** - M4 общий uplink через mesh из 3 узлов + M5 измеренная сходимость самовосстановления. Deliverable: видео + метрики + Apache-2.0 + Zenodo DOI. **Одновременно - первый двойной demo**: mesh-transport + DePIN-node (transport-proof + coverage-proof живые).
  «Треугольник, который сам себя чинит.»
- **P3 - video-radio + управление узлом (telemetry)** - один радиоканал несёт mesh + телеметрию + видео.
- **P4 - привязной воздушный узел (elevated relay)** - постоянно висящий узел над точкой интереса.
- **P5 - свободный swarm** - самоорганизующийся swarm без tether'а, каждый узел это operator, каждый operator получает TRI.
- **P6 - Trinity silicon (BLOCKED, маршрута нет)** - изготовленного кристалла не существует, изготовление не запланировано, прежний маршрут закрыт. До выбора нового маршрута BitNet benchmark на кристалле невыполним, `[Open conjecture]` компонентов compute-anchor'а закрывается.
- **P7 - Genesis Day** - развёртывание `trinity-contracts` в mainnet на Base L2, `EmissionController.renounceOwnership()`, первый public proof-of-inference за TRI.
- **P8 - Hub71+ AI Cohort 20 (deadline 2026-08-02)** - подача через `golden-chain-international` (UAE ADGM/DIFC, Армения-резерв).

## Платы

| Плата | Чип | Роль |
|---|---|---|
| ALINX AX7203 | Artix-7 `xc7a200t` (IDCODE `0x13636093`) | стендовые вычисления + video-radio + 2×GbE mesh (проверено на кристалле через openXC7 + OpenOCD + AL321) |
| **P201/P203 Mini** × 3 | Zynq-7020 `xc7z020` + AD9361 SDR + GPS/PPS | **MVP летающего DePIN-узла** - M1 crypto `hw`, AD9361 PHY `hw`, три платы соединены |

---

## Научная база - Trinity papers RU (трек ВАК)

Научный корпус, на который опирается mesh + DePIN-стек, публикуется в
[`gHashTag/trinity-papers-ru`](https://github.com/gHashTag/trinity-papers-ru).
Российский трек ВАК ведётся параллельно с международным препринт-каналом.

| Артефакт | Формат | Целевой журнал | Категория | Roadmap-slot |
|---|---|---|---|---|
| GoldenFloat GF16 (arXiv:2606.05017) | LaTeX + PDF (22 стр.) | «Программирование» / Programming and Computer Software (ИСП РАН, Pleiades/Springer) | К-1 (Scopus) | базис `gf16` модуля (M2 `-sim`) |
| Каталог 83 численных форматов | Word (20 стр.) | «Искусственный интеллект и принятие решений» (ФИЦ ИУ РАН) | К-1 | базис ternary-inference плеча |
| «Россия 3.0 — Троица» (открытое обращение) | Markdown + LaTeX + PDF (12 стр.) | рецензируемый журнал ВАК | - | стратегическая рамка DePIN-развёртывания |
| GoldenFloat + Сетунь (Habr) | Markdown + 5 иллюстраций | Habr | scipop | внешний нарратив |

Требование ВАК (2026): ≥ 2 статьи, минимум одна К-1/К-2 («Белый список» РЦНИ / RSCI / Scopus). Обе профильные статьи выше - К-1, требование закрывается с запасом.

Sister-репозитории: [`gHashTag/t27`](https://github.com/gHashTag/t27), [`gHashTag/goldenfloat-preprint`](https://github.com/gHashTag/goldenfloat-preprint), [`gHashTag/paper3-methodology`](https://github.com/gHashTag/paper3-methodology).

Автор корпуса: Дмитрий Васильев · ORCID [0009-0008-4294-6159](https://orcid.org/0009-0008-4294-6159) · admin@t27.ai.

---

## Заметки по проектированию

- **Направленные nonce.** Инициатор отправляет с байтом направления nonce `0`,
  отвечающая сторона - `1`, поэтому два TX-счётчика никогда не сталкиваются в
  пределах одного сессионного ключа.
- **Аутентификация раньше replay.** Тег кадра проверяется до обращения к
  replay-окну, поэтому подделанные счётчики не могут отравить окно.
- **Заголовок аутентифицирован.** Wire-заголовок (src/dst/ttl) передаётся как
  associated data для AEAD - изменённый байт маршрутизации не проходит
  аутентификацию.
- **Нет `unsafe`** (`#![forbid(unsafe_code)]`); криптография - RustCrypto + dalek.
- **Нет чипа - нет TRI.** Любой путь DePIN-proof, позволяющий начислить награду
  без действительной подписи чипа Trinity, есть нарушение протокола, каким бы
  удобным он ни был.

## Связанные репозитории

- [`gHashTag/trinity-contracts`](https://github.com/gHashTag/trinity-contracts) - контракты майнинга на Base L2 (TRI, MiningPool, EmissionController, ChipRegistry, JobProver, IGLALedger, BittensorSubnetAttest).
- [`gHashTag/trinity-node`](https://github.com/gHashTag/trinity-node) - DePIN-демон (HAL / Attestation 2-of-3 / Consensus / Miner loop 12 s / Validator 30 s / PoRep / PoC Helium stub / JSON-RPC :9933).
- [`gHashTag/trinity-sdk`](https://github.com/gHashTag/trinity-sdk) - Python API для DePIN AI devs.
- [`gHashTag/trinity-papers-ru`](https://github.com/gHashTag/trinity-papers-ru) - русские версии Trinity-статей для ВАК.
- [`gHashTag/golden-chain-international`](https://github.com/gHashTag/golden-chain-international) - международное ASCII-издание (UAE ADGM/DIFC, Hub71+ AI Cohort 20).
- [`gHashTag/paper3-methodology`](https://github.com/gHashTag/paper3-methodology) - каталог 83 численных форматов.
- [`gHashTag/t27`](https://github.com/gHashTag/t27), [`gHashTag/tt-trinity-phi`](https://github.com/gHashTag/tt-trinity-phi), [`gHashTag/tt-trinity-euler`](https://github.com/gHashTag/tt-trinity-euler), [`gHashTag/tt-trinity-gamma`](https://github.com/gHashTag/tt-trinity-gamma), [`gHashTag/trinity-clara`](https://github.com/gHashTag/trinity-clara).

## Ключевые документы

- [`docs/LOCAL_FLASH.md`](docs/LOCAL_FLASH.md) - пошаговая локальная прошивка трёх плат.
- [`docs/WAVE_DEPIN_2026-07-04.md`](docs/WAVE_DEPIN_2026-07-04.md) - DePIN whitepaper (четыре плеча, tokenomics, positioning).
- `docs/COMPETITOR_MATRIX_2026-07-04.md` - 10 MANET-конкурентов × 15 полей (в [PR #28](https://github.com/gHashTag/tri-net/pull/28)).
- [`docs/_recon/DEPIN_COMPETITORS_2026-07-04.md`](docs/_recon/DEPIN_COMPETITORS_2026-07-04.md) - 12 DePIN-сетей × 12 полей.
- [`docs/WAVE_N3_AUDITABILITY_GAP_2026-07-04.md`](docs/WAVE_N3_AUDITABILITY_GAP_2026-07-04.md) - статья про δ auditability.
- [`docs/STRENGTHEN.md`](docs/STRENGTHEN.md) - научно-ориентированный backlog.
- [`docs/AUTONOMOUS.md`](docs/AUTONOMOUS.md) - политика human-merge only для agent PR's.

## Лицензия

Apache-2.0.

Anchor: **φ² + φ⁻² = 3**.
