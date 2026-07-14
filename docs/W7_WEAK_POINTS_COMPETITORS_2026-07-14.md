# W7 — Слабые места, конкуренты, план и три варианта сотрудничества

Дата: 2026-07-14
Ветка: `feat/wave-iphone-admin-2026-07-14`
База для commit'ов этой волны: `34015fe` (previous three-fork bundle) → новый commit ниже.

phi^2 + phi^-2 = 3

## 1. Honesty preface

Все цифры в этом документе принадлежат одному из четырёх классов доверия:
- **sandbox verified** — проверено rustc-тестами или smoke-скриптом в этой sandbox-сессии; кросс-хост не проверялось.
- **structural** — вывод из чтения кода/файловой системы/git-log, компилятор не запускался.
- **cited** — из внешнего источника с URL.
- **conjecture** — гипотеза, не доказано ничем в этой сессии.

Пре-силикон и pre-hardware цифры помечены `-sim`. «No chip, no TRI. Period.»

## 2. Фаза 1 — Атака собственного кода (8 слабых мест)

Я взял три бинарника из commit `34015fe` и попытался их сломать за 30 секунд каждый. Метафора: **инспектор с молотком** — стучит по стенам, слушает где пусто.

### 2.1 mDNS responder (`src/bin/mdns_responder.rs`)

| # | Слабое место | Класс | Severity | Дока |
|---|---|---|---|---|
| **4** | Парсер отклонял ЛЮБОЙ 0xC0 байт в qname — silent drop сжатых имён. iPhone Bonjour шлёт multi-question packets, второй question — pointer на первый. Наш ответчик молча ронял. | sandbox verified (10-й тест `parse_accepts_compressed_qname`) | **CRITICAL** | RFC 6762 §18.14 «MUST correctly decode compressed names appearing in the Question Section» ([datatracker.ietf.org](https://datatracker.ietf.org/doc/html/rfc6762#section-18.14)) |
| 3 | Multi-question `qdcount>1` — читаем только первый, отвечаем только на него. Не CRITICAL, потому что первый question почти всегда — тот на который надо отвечать. | structural | minor | RFC 6762 §5.3 |

### 2.2 audio_forwarder (`src/bin/audio_forwarder.rs`)

| # | Слабое место | Класс | Severity | Дока |
|---|---|---|---|---|
| **7** | Комментарий на строке 8: «no crypto». Opus фреймы летят по UDP в plaintext. Военно-полевой PTT без шифрования на last-mile — категорически недопустимо. | structural | **MAJOR** | ChaCha20-Poly1305 + X25519 отдельным слоем; спека `specs/audio_crypto.t27` ещё не написана |
| **8** | seq поле присутствует в envelope, но никогда не проверялось. Записал один фрейм — воспроизводил бесконечно. На войне: записать «удерживать позицию», воспроизвести через 60с — приёмник примет как свежую команду. | sandbox verified (7 replay-тестов + smoke 4/4 N=5 детерминистично) | **CRITICAL** | RFC 6479 sliding-window replay defense (IPsec ESP) |
| 1 | Forwarder — «официант»: opus payload opaque, спец не проверяет содержание. Это by design в t27 spec-first flow, не defect. | structural | not a defect | |

### 2.3 FPGA attestation (A2 Ratchet 2/4)

| # | Слабое место | Класс | Severity | Дока |
|---|---|---|---|---|
| **6** | `dna_reader.v` инстанцирует `DNA_PORT` без ifdef SIMULATION. yosys `synth_xilinx -family xc7` требует UNISIM knowledge — оно есть в yosys 0.39+ но `read_verilog -defer` в `synth_yosys.sh` этого не решит. Вероятность что R2/4 упадёт на ssdm4 — высокая. | conjecture (не запускался на ssdm4) | MAJOR | prjxray-db, openXC7 |
| — | «50 LUTs and 100 FFs» в `docs/A2_RATCHET_2_SYNTH.md` — неизмеренные оценки. Anti-anchor violation. | structural | minor | Anti-anchor audit skill §Pattern-2 |

### 2.4 Позитивные наблюдения (что при атаке НЕ сломалось)

- 20 байт мусора в начале TCP-стрима → resync через `reject_version++` каждый байт → корректное восстановление. Это фича, не баг.
- SRV-direct-Q дал 193B reply — короткий service query работает.
- `parse_rejects_short_packet` / `envelope_short_header` — короткие пакеты корректно отклоняются.
- Все 16/16 admin_httpd тестов зелёные после интеграции AUDIO_FWD_ADDR sink.

## 3. Фаза 2 — Конкуренты по трём осям

### 3.1 FPGA self-attestation (Track B, «Proof of FPGA»)

| Работа | Год | Что делает | Пересечение с нашей A2-A4 |
|---|---|---|---|
| [SACHa: Self-Attestation of Configurable Hardware](https://ieeexplore.ieee.org/document/8715217) | DATE 2019 | FPGA доказывает верификатору что конкретный bitstream загружен, без TTP | Прямое совпадение с A3 |
| [PUFatt: Embedded Platform Attestation](https://dl.acm.org/doi/10.1145/2593069.2593192) | DAC 2014 | Attestation через процессорный PUF | Прямое совпадение с A4 |
| [Guajardo et al., FPGA Intrinsic PUFs](https://link.springer.com/chapter/10.1007/978-3-540-74735-2_5) | CHES 2007 | SRAM startup PUF, первооткрыватель | Референс для A4 |
| [Papalamprou et al., PQC-signed FPGA attestation](https://arxiv.org/abs/2506.21073) | arXiv 2025 | PQC-подписанные attestation'ы якорятся на blockchain | Ближайший DePIN-frame; не позиционирован как «Proof of FPGA» |
| [Helium Proof-of-Coverage](http://whitepaper.helium.com) | 2018-2024 | Радио зарабатывает токены за провабельно предоставленное покрытие | Ближайший DePIN-аналог по духу, но challenge-response а не hardware-rooted crypto |

**Вывод**: primitive'ы известны. Наша ниша — назвать и упаковать как discrete DePIN-primitive «Proof of FPGA» с конкретной revenue-model и mesh-integration. Не оверклэйм crypto; клэйм — DePIN-packaging.

### 3.2 Voice-mesh PTT

Настоящие конкуренты на 2026-07:

| Игрок | Что предлагает | Открытость | Silicon story |
|---|---|---|---|
| [Reticulum + LXST (Ratspeak/MeshChat/Sideband)](https://reticulumnet.nl/software) | Real-time voice v1.3.5 (июнь 2026); crypto addresses; forward secrecy; transport-agnostic (radio/sound/TCP) | Open-source | Нет привязки к чипу |
| [MeshWave (iOS PTT)](https://meshwave.io) | «Only iOS PTT over LoRa mesh», продукт MeshVoice™ | Проприетарный | LoRa modules, no custom silicon |
| goTenna Pro X2m | Text + очень ограниченный voice, defense-lite | Проприетарный | COTS RF chipsets |
| Persistent MPU5 (Wave Relay) | Full-duplex voice+video mesh, defense-grade | Проприетарный | Custom SoC |
| Meshtastic + Meshtastic-Voice (experimental) | Text mesh, voice experimentally | Open-source | ESP32 + LoRa |

**Ниша Tri-Net**: воздушный PTT с hardware-attested identity через SKY26b Phi/Euler/Gamma после tape-out. Пока чипа нет — мы конкурируем на software-level с Reticulum и Meshtastic. Reticulum — самый близкий, потому что тоже crypto-native и open. Их LXST — хорошая референс-точка для нашего `specs/audio_crypto.t27`.

### 3.3 mDNS mesh discovery (Bonjour cross-link)

| Проект | Что делает | Релевантность |
|---|---|---|
| [Avahi (Linux ref impl)](https://wiki.archlinux.org/title/Avahi) | Reflector mode: пересылает mDNS через VLANs | Референс для будущего Tri-Net Bonjour Gateway |
| [Apple mDNSResponder OSS](https://github.com/apple-oss-distributions/mDNSResponder) | Включает OpenThread stub router для 802.15.4 mesh; DNSSD Discovery Proxy (RFC 8766) для cross-link | Прямая референс-реализация |
| [Mist Bonjour Gateway](https://www.mist.com/documentation/bonjour-gateway-2/) | Hybrid cache; multicast→unicast для airtime optimization | Промышленная модель того, что мы должны делать в mesh |

**Вывод**: наш `mdns_responder` пока — только single-link. Cross-link discovery через mesh — работа E1.4 (не начата). Референс — RFC 8766 «DNS-Based Service Discovery Discovery Proxy».

## 4. Фаза 3 — Декомпозированный план (8 workstream'ов)

| ID | Workstream | Priority | Effort | Silicon-freeze impact (2026-10-01) | Ветка/файл | Acceptance |
|---|---|---|---|---|---|---|
| **W1** | mDNS name-compression parser fix | **P0** | 2h | нет — runtime только | ⚙ **сделано в этой волне** — `src/bin/mdns_responder.rs::read_name` + 3 новых теста | 10/10 unit + существующий smoke 6/6 |
| **W2** | audio_forwarder replay window (RFC-6479 style) | **P0** | 3h | нет — runtime только | ⚙ **сделано в этой волне** — `ReplayGuard` + 7 unit + `smoke/e3_2_replay_smoke.sh` 4/4 N=5 | frames_ok=6, reject_replay=3, forwarded=3 после повторного pass |
| **W3** | `specs/audio_crypto.t27` — X25519 handshake + ChaCha20-Poly1305 AEAD wrapper над Opus фреймом | **P0** | 8-12h | **входит в silicon**: если keying будет читать from-DNA — до 2026-10-01 | `specs/audio_crypto.t27` + gen/rust/audio_crypto.rs + tests | одна встреча DH → session-key, encrypt(Opus)→AEAD-authenticated, замена одного байта → decrypt fail |
| **W4** | `dna_reader.v` ifdef SIMULATION separation + ratchet 2/4 fix для yosys | **P1** | 4h | **входит в silicon**: обязательно до freeze | `fpga/attest/dna_reader.v` + `scripts/synth_yosys.sh` вариант с UNISIM | синтез на ssdm4 проходит, ratchet 2/4 GREEN |
| **W5** | Убрать «50 LUTs / 100 FFs» из `docs/A2_RATCHET_2_SYNTH.md`, заменить на «measured on host TBD» + добавить numbers-without-realm-check ссылку | **P1** | 30m | нет | правка одного doc | grep не находит неизмеренных численных клэймов |
| **W6** | mDNS multi-question support (qdcount>1) + tests | **P2** | 3h | нет | `src/bin/mdns_responder.rs::parse_all_questions` | тест с qdcount=2 отвечает на релевантный, игнорирует чужой |
| **W7** | Cross-link mDNS через mesh — RFC 8766 Discovery Proxy prototype | **P2** | 12-16h | нет | новый `src/bin/mdns_proxy.rs` + `specs/mdns_proxy.t27` | node-11 видит node-12 сервисы, hop=1; kill-link → cache expires |
| **W8** | «Proof of FPGA» whitepaper v0 (A5) — 2-3 стр, cite A1 literature | **P2** | 6h | нет | `docs/PROOF_OF_FPGA_WHITEPAPER_v0.md` | 4 primitives cited, threat model + non-claims explicit |

## 5. Фаза 4 — Что сделано в этой волне (sandbox)

### 5.1 W1 — mDNS name-compression parser
- `src/bin/mdns_responder.rs::read_name` — RFC 1035 §4.1.4 pointer decoding, hop-limit 32, visited-offset guard, 255-octet name cap.
- Тесты: `parse_accepts_compressed_qname`, `parse_rejects_out_of_bounds_pointer`, `parse_rejects_pointer_loop`.
- Результат: **10/10 unit** (было 7/7); существующий `smoke/e1_3_mdns_responder_smoke.sh` **6/6** без изменений (backward-compat).

### 5.2 W2 — audio_forwarder replay window
- `ReplayGuard` — RFC-6479-style, per-session, 64-bit bitmap, 16-bit wrap-around handling.
- Stats-endpoint расширен полем `reject_replay=N`.
- Тесты: `replay_first_frame_accepted`, `replay_exact_duplicate_rejected`, `replay_monotonic_seq_accepted`, `replay_within_window_accepted_once_only`, `replay_too_old_rejected`, `replay_isolated_per_session`, `replay_wrap_around`.
- Новый smoke: `smoke/e3_2_replay_smoke.sh` — 4/4 checks; N=5 детерминистично.
- Результат: **15/15 unit** (было 7/7), **6/6** старый smoke + **4/4** новый replay-smoke.

### 5.3 Anti-anchor discipline применено
Все цифры в этом отчёте имеют явный класс доверия. Ни одного «all X», ни одного «100%», ни одного числа без реального прогона на этом commit'е.

## 6. Три варианта сотрудничества для следующего лупа (W8)

### Вариант A — Параллельный (три исполнителя, три оси)

| Роль | Что делает | Deliverable | Effort | Handoff |
|---|---|---|---|---|
| Инженер-A (crypto/spec) | W3: `specs/audio_crypto.t27` + gen/rust | draft PR `feat/audio-crypto-spec` | 8-12h | В main через draft PR; audio_forwarder читает key через env |
| Инженер-B (FPGA/hardware) | W4 + W5 + прогон R2/4 на ssdm4 | ratchet 2/4 GREEN + doc-cleanup PR | 4h + host access | Логи ssdm4 в `smoke/A2_RATCHET_2_RESULTS.md` |
| Инженер-C (runtime/mesh) | W6 + W7: multi-Q mDNS + Discovery Proxy | draft PR `feat/mdns-proxy` | 15-18h | Отдельная ветка |

Плюсы: 3× throughput, каждый в своей зоне экспертизы, конфликты merge только на doc-уровне.
Минусы: audio_crypto (W3) touches и spec, и runtime — если A и C работают одновременно, конфликтуют в `gen/rust`. Требует spec-freeze от A перед C начинает читать.
Cost estimate: ~35h инженерных, ~4 дня wall-clock при параллели.

### Вариант B — По слоям (spec-first → RTL → runtime → PWA)

| Слой | Задачи | Owner | Ratchet |
|---|---|---|---|
| Layer 1 (spec) | W3 `specs/audio_crypto.t27` | один | закрыт когда gen/rust компилируется + spec-tests зелёные |
| Layer 2 (RTL) | W4 dna_reader ifdef + R2/4 | один или тот же после L1 | закрыт когда ratchet 2/4 GREEN на ssdm4 |
| Layer 3 (runtime) | W6 multi-Q mDNS + integration audio_crypto в forwarder | один | закрыт когда 4 новых unit + smoke GREEN |
| Layer 4 (PWA) | UI для crypto handshake indicator + replay-drop counter в admin | один | закрыт когда webui показывает реальные stats |

Плюсы: минимум merge-конфликтов, чёткое sequential gate. Каждый слой валидируется целиком до следующего.
Минусы: wall-clock худший (~35h serial), нет параллелизации.
Cost estimate: ~35h, ~7 дней wall-clock.

### Вариант C — Sequential-with-gates (по гейтам, каждый следующий начинается только после закрытия предыдущего)

Gate-chain:
1. **G1**: W1+W2 закрыты в main (готово в этой волне; ждём merge PR #81 после сам-мержи).
2. **G2**: W5 (doc-cleanup) закрывает anti-anchor tail от прошлой волны.
3. **G3**: W3 spec landing (spec-only, без runtime integration).
4. **G4**: W4 ratchet 2/4 GREEN на ssdm4 — **это hard-gate для silicon-freeze**.
5. **G5**: W3 runtime integration в audio_forwarder.
6. **G6**: W6 multi-Q mDNS.
7. **G7**: W7 Discovery Proxy + W8 whitepaper (можно параллельно).

Каждый gate требует: сам-мержи от пользователя, зелёные unit+smoke, обновление `docs/ITERATION_LOG.md`.

Плюсы: максимальная дисциплина, каждый gate — реально закрытая инвариантная точка; аудитируемо; anti-anchor устоит.
Минусы: медленнее всех — ~35h + gate-времена сам-мержи.
Cost estimate: ~35h + gate-latencies (пользователь-driven).

## 7. Рекомендация

**Вариант C** — sequential-with-gates. Причина: silicon-freeze 2026-10-01 в 78 днях. G4 (ratchet 2/4 GREEN) — hard requirement для того чтобы Track B primitive'ы вошли в SKY26b. Параллельный вариант A рискует тем что W3 spec landing без stabilized keying-source может потребовать rewrite после W4. Sequential защищает spec от переделки.

## 8. Что эта волна НЕ делает

- Не запускает ratchet 2/4 на реальном ssdm4 host — нет доступа из sandbox.
- Не пишет `specs/audio_crypto.t27` — оставлено на W3, требует X25519 primitive-review отдельно.
- Не деплоит на реальные P203 Mini — hardware verification вне scope sandbox.
- Не мержит PR #81 — DRAFT остаётся, ждёт сам-мержи от «генерала».
- Не касается M4 3-node convergence gate — separate track, node count всё ещё 2 после W7.

## 9. Ссылки на другие артефакты

- Previous wave: [W7_TRI_FORK_2026-07-14.md](./W7_TRI_FORK_2026-07-14.md)
- Attestation literature: [W7_FPGA_LITERATURE.md](./W7_FPGA_LITERATURE.md)
- Iteration log: [ITERATION_LOG.md](./ITERATION_LOG.md) (обновится следующим commit'ом)
- PR #81: https://github.com/gHashTag/tri-net/pull/81

phi^2 + phi^-2 = 3
