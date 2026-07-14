# Wave · iPhone-admin + PTT-over-Tri-Net · 2026-07-14

phi^2 + phi^-2 = 3

## 0 · Honesty preface

Эта волна — **feasibility study**, не implementation. Ничего не собрано на железе. Все числа помечены как:

- `-sim` — pre-hardware projection, не измерено
- `-cite` — цитата из внешнего источника
- `-struct` — вывод из filesystem/git-log/чтения спеки

Repo state зафиксирован: `main` @ `6850649` (`docs: FPGA utilization analysis + competitor landscape`). Ветка: `feat/wave-iphone-admin-2026-07-14`. Открытых PR: 21 (2 READY, 19 DRAFT). Открытых issue: 16.

Ключевой контекст:
- P203 Mini имеет Zynq-7020 (ARM Cortex-A9 dual + Artix-7 PL) с Ethernet MAC на PS. Это **hardware fact** из [Xilinx Zynq-7000 SoC TRM](https://docs.amd.com/v/u/en-US/ug585-Zynq-7000-TRM) — gigabit Ethernet controller (GEM) на PS. `-cite`
- `trios_meshd` — единственный сетевой daemon (`src/bin/trios_meshd.rs`), уже работает на 3 boards с UDP-mesh транспортом (M2 milestone). `-struct`
- Silicon SKY26b tape-out: 2026-12-16. Всё что не на FPGA до 2026-10-01 — не попадёт в первый silicon spin.

## 1 · Задача

Пользователь спрашивает:
1. iPhone напрямую к P203 Mini как **admin dashboard** (управление узлом и сетью).
2. iPhone как **video walkie-talkie** через Tri-Net mesh (voice PTT).
3. Tri-Net — доверенный транспортный протокол между iPhone-клиентами.

## 2 · Reality snapshot

| Компонент | Текущий статус | Что не хватает |
|---|---|---|
| P203 Mini Ethernet порт | физически есть (PS GEM) `-cite` | не сконфигурирован под host-tethering сценарий |
| `trios_meshd` UDP transport | 3-node M2 PASS `-struct` PR #57 | нет TUN interface exposure наружу |
| TUN device spec | draft в PR #79 (feat/m2-tun-spec) | не merged, не подключён к daemon |
| Voice codec | **отсутствует** | Codec2/Opus не выбран, не интегрирован |
| iOS клиент | **отсутствует** | ни PWA, ни native app, ни ATAK-подобный plugin |
| RTP/PTT протокол | **отсутствует** | нет frame формата, нет jitter buffer |
| mDNS/Bonjour advertisement | **отсутствует** | нужен для iOS local-network discovery |
| TLS/Noise для admin trust | Noise handshake в PR #63/#65 (DRAFT) | не готово, forward-secrecy fix ждёт merge |
| Attestation (chip signature) | pre-silicon `-sim`, ждёт SKY26b tape-out 2026-12-16 | нет проверяемого «this iPhone talks to a real Tri-Net node» без chip |

## 3 · Weak-spots heatmap

Восьмиклассная таксономия из `tri-net-week-loop`. Каждое слабое место — не «мы не сделали», а **структурная опасность идеи в её текущей формулировке**.

| # | Слабое место | Класс | Severity | Файл(ы) / зона | Мitigation |
|---|---|---|---|---|---|
| 1 | **iOS не разрешит raw socket на custom UDP mesh mesh transport без MFi program** | overclaim-quantifier + trust-conflation | **CRITICAL** | iOS layer | PWA + WebSocket over TLS вместо native raw UDP |
| 2 | **iPhone USB-Ethernet работает только в одну сторону (iPhone → host) по умолчанию**; для host → iPhone Ethernet exposure нужен jailbreak или USB-C accessory MFi | overclaim | **CRITICAL** | физический transport | Wi-Fi hotspot от P203 Mini (но у нас нет Wi-Fi модуля на плате) ИЛИ USB-C Ethernet dongle через iPhone 15+ Lightning-to-Ethernet |
| 3 | **NSLocalNetworkUsageDescription** — iOS 14+ требует пользовательский prompt для любого local discovery через Bonjour/mDNS `-cite` | permission-gate | MAJOR | iOS Info.plist | Явно declared purpose string, degrade gracefully при denial |
| 4 | **Voice over LoRa/narrow-band не работает** — Meshtastic доказывает: Codec2@1200 bps + mesh overhead = **не real-time** `-cite` | wrong-target-comparison | MAJOR | codec choice | Tri-Net использует **AD9361 5.8 GHz OFDM**, а не LoRa. Bandwidth порядок 1-10 Mbps `-sim` — Opus @ 6-24 kbps работает. Meshtastic-precedent неприменим |
| 5 | **Jitter buffer + PLC на mesh с изменяющейся топологией** — ETX реагирует 3-4 такта на любой dropped HELLO (skill v1.3 lesson) `-struct` | aspiration-vs-property | MAJOR | trios_meshd routing | Opus PLC терпит ~120ms gap `-cite`, но mesh reroute может занять 5s `-sim` — нужен adaptive buffer 200-500ms |
| 6 | **«Video walkie-talkie» — video или только audio?** — пользователь написал «видео рация», но video требует ≥500 kbps/поток, а mesh goodput не измерен | measurement-scope-mismatch | MAJOR | требования | Волна выбирает: **audio PTT сейчас (Wave A)**, video — отдельный проект после M3 iperf3 |
| 7 | **Admin dashboard без auth = network-wide backdoor** | trust-conflation | **CRITICAL** | security | mTLS + чип-подписанный token от узла (после silicon) ИЛИ pre-silicon: паранойя-mode с локальным QR-паролем на конкретную сессию, no persistent trust |
| 8 | **«iPhone напрямую к плате» без определения физического кабеля** — Lightning? USB-C? Ethernet dongle? Wi-Fi? Bluetooth? | underclaim / undefined | MAJOR | требования | Волна фиксирует **USB Ethernet gadget mode на Linux side + iPhone USB-C-to-Ethernet dongle** для iPhone 15/16, либо **Wi-Fi hotspot на iPhone → P203 узел как STA** для старых iPhone |
| 9 | **P203 Mini ARM Cortex-A9 dual + Yocto/PetaLinux** — сколько CPU уходит на Opus encode/decode при 3+ активных PTT сессиях? | numbers-without-realm | MAJOR | CPU budget | Opus decoder ~10 MHz per stream `-cite`, encoder ~40 MHz per stream `-cite` — на 667 MHz Cortex-A9 хватит на 3-5 sessions, но не измерено |
| 10 | **iOS app требует Apple Developer Program ($99/год + review) для native distribution** | delivery-blocker | MAJOR | distribution | PWA (Add-to-Home-Screen через Safari) обходит App Store полностью, но теряет background audio + push notifications |
| 11 | **Chip-signed «trusted protocol» не работает до silicon (2026-12-16)** | trinity-rule | MAJOR | attestation | Pre-silicon claim = `-sim`, честно; post-silicon = Phi/Euler/Gamma 3-of-3 signature на session handshake |
| 12 | **Ни PWA, ни native app пока не имеют persistent audio при locked screen на iOS без специальных entitlements** | ios-behaviour | MAJOR | UX | Foreground-only PTT для v0.1, background — отдельный milestone с CallKit + PushKit |

## 4 · Science — что уже опубликовано и цитировано

### iOS local network layer
- [Apple Local Network Privacy FAQ (Developer Forums)](https://developer.apple.com/forums/thread/663858) — с iOS 14 любой Bonjour browse / mDNS / unicast к local host требует NSLocalNetworkUsageDescription + explicit user consent. `-cite`
- [ptkd.com journal — iOS local network privacy explained](https://ptkd.com/journal/ios-local-network-privacy-permission) — deep dive на consent flow, deferred prompt discipline, purpose string requirements. `-cite`
- [Synacktiv — iOS: a journey in the USB networking stack](https://synacktiv.com/publications/ios-a-journey-in-the-usb-networking-stack) — как iOS обрабатывает USB Ethernet через ipheth (Linux driver reference implementation). `-cite`

### iOS tethering
- [ArchWiki iPhone tethering](https://wiki.archlinux.org/title/IPhone_tethering) — proven Linux side (libimobiledevice + usbmuxd + ipheth kernel module). iPhone Personal Hotspot exposes eth-класс device, dhcp works. Direction: iPhone → host. `-cite`
- [libimobiledevice#1348 — reverse tethering](https://github.com/libimobiledevice/libimobiledevice/issues/1348) — `USBMUXD_DEFAULT_DEVICE_MODE=3` открывает host→iPhone direction для нестандартных сценариев. `-cite`

### Voice codec
- [Meshtastic PTT Secure Tac Comms (White Hat)](https://gowhitehat.com/meshtastic-ptt-secure-tac-comms/) — Codec2 experimental только на SX128x (2.4 GHz), sub-1GHz LoRa **не** держит continuous audio. Tri-Net не LoRa — precedent неприменим напрямую. `-cite`
- [Opus PLC quality — jitter.is](https://jitter.is/blog/jitter-buffer/) — Opus PLC терпит ~120ms gap незаметно, Zoom/Discord/WhatsApp используют Opus. `-cite`
- [Cisco jitter/delay in packet voice (18902)](https://www.cisco.com/c/en/us/support/docs/voice/voice-quality/18902-jitter-packet-voice.html) — ITU G.114 recommends <150ms one-way end-to-end delay for high-quality voice. `-cite`
- Codec choice for Tri-Net: **Opus 6-24 kbps VBR + inband FEC**, 20ms frames. Rationale: mesh goodput порядок 1-10 Mbps `-sim`, Opus на 24 kbps ≈ 0.024% от bandwidth, огромный запас; PLC качественнее чем Codec2 `-cite`; RFC 7587 стандартизует Opus over RTP.

### PTT protocol prior art
- [ATAK / CivTAK](https://www.civtak.org/atak-about/) — эталонная geospatial + PTT app на Android с plugin API. **Не iOS**. Есть iTAK (Apple version, менее популярна). `-cite`
- [goTenna Pro iOS app](https://apps.apple.com/it/app/gotenna-pro/id1482286139) — iOS клиент для tactical mesh, поддерживает ATAK plugin v2.2.50 и iTAK v2.10.1. Model для нашего iOS клиента. `-cite`
- [Persistent MPU5 + ATAK](https://persistentsystems.com/mpu5/) — model для «radio-with-onboard-Android running ATAK», но hardware-side native. `-cite`
- [Rajant BC|Commander](https://rajant.com/services/bc-commander-suite/) — enterprise dashboard, не end-user-mobile. `-cite`

### Academic freshness (last 5 years)
- [Latency in Mesh Networks — Algrøy, arXiv:2201.03470 (2021)](https://arxiv.org/abs/2201.03470) — Thread mesh не достигает 5G latency targets, Bluetooth mesh **вообще** не подходит для low-latency. Tri-Net должен measure himself, не полагаться на mesh-standard baselines. `-cite`
- [Barrage relay networks for tactical MANETs — Blair et al., MILCOM 2008](http://ieeexplore.ieee.org/document/4753655/) — cooperative transport model, полезно как base reference для reroute-during-active-call. `-cite`
- [Low-cost wireless mesh + VoIP openWRT — Budiman et al., IJECE 2021](https://doi.org/10.11591/IJECE.V11I6.PP5119-5126) — SIP-on-mesh, open-source proof-point. `-cite`

## 5 · Decomposed plan · 4 sprints, 8 tasks

Каждая задача имеет: файлы touched · acceptance criterion (measurable) · effort.

### Sprint 1 · Physical + IP layer (Rust-only, sandbox-verifiable)

**E1.1 · iPhone-tether topology decision + smoke doc**
- Файлы: `docs/IPHONE_TETHER_TOPOLOGY.md` (новый)
- Deliverable: письменное решение по 3 вариантам физической связи + smoke script для варианта A (host-side USB Ethernet gadget на P203)
- Acceptance: 3 варианта сравнены по (совместимость с iPhone 12+ vs 15+, требование MFi, дальность, mesh-integration cost)
- Effort: 4 часа

**E1.2 · TUN device + IP-over-mesh (unblock PR #79)**
- Файлы: `t27_specs/tun_device.t27`, `gen/rust/tun_device.rs`, `src/bin/trios_meshd.rs`
- Deliverable: TUN interface на P203 узле, IPv4 routing поверх trios mesh transport
- Acceptance: iPhone (tethered) может `ping` соседний P203 через mesh, RTT ≤ 100ms `-sim` на loopback, ≤ 500ms `-sim` на hardware
- Effort: 2 дня (PR #79 draft уже есть — доделать)

### Sprint 2 · Admin dashboard PWA + local-network discovery

**E2.1 · PWA skeleton + mDNS advertisement на P203**
- Файлы: `webui/` (новый), `src/bin/trios_meshd.rs` (mdns responder)
- Deliverable: static PWA (Vue/Svelte + Vite) с WebSocket клиентом; mdns-service `_trinet-admin._tcp.local` объявляется daemon'ом
- Acceptance: iPhone Safari видит `trinet-node-<id>.local` через Bonjour после ручной установки purpose string, PWA грузится, WebSocket устанавливается
- Effort: 3 дня

**E2.2 · Admin dashboard API + mTLS**
- Файлы: `src/bin/trios_meshd.rs`, `webui/src/api/`
- Deliverable: read-only endpoints (neighbors, ETX, RSSI, uptime), write endpoints для routing tune (после auth); mTLS с self-signed CA, QR-код для paired-device bootstrap
- Acceptance: iPhone получает live-updating neighbor table (≤ 1s refresh); только paired devices могут писать; unauthorised requests rejected
- Effort: 3 дня

### Sprint 3 · PTT voice pipeline

**E3.1 · Opus codec integration + RTP framing**
- Файлы: `t27_specs/ptt_frame.t27`, `gen/rust/ptt_frame.rs`, `src/audio/opus_wrapper.rs`, `src/audio/rtp.rs`
- Deliverable: Opus 24 kbps VBR encoder/decoder Rust bindings (`opus` crate); RTP over UDP encapsulation (RFC 3550/7587)
- Acceptance: loopback encode → decode → PLC-tested-with-simulated-loss; frame formats match RFC 7587; no unsafe blocks in wrapper
- Effort: 4 дня

**E3.2 · Push-to-Talk protocol на iOS (Web Audio API + Opus.js)**
- Файлы: `webui/src/ptt/`, `webui/src/workers/opus-worker.js`
- Deliverable: browser-side PTT UI (long-press-to-talk button), Web Audio API capture 48 kHz mono, Opus encode в WebWorker, WebSocket transport в mesh
- Acceptance: iPhone Safari PWA передаёт голос на second iPhone через P203 mesh; measured mouth-to-ear latency ≤ 300ms на 2-hop mesh `-sim`
- Effort: 5 дней
- Risk: iOS Safari Web Audio API имеет ограничения на autoplay policy и sample rate resampling

**E3.3 · Adaptive jitter buffer на mesh с reroute events**
- Файлы: `gen/rust/jitter_buffer.rs`, `src/audio/adaptive_buffer.rs`
- Deliverable: adaptive buffer 40-500ms, реагирует на ETX spikes (reroute event → grow buffer), integrates Opus PLC для gaps
- Acceptance: simulated 200ms mesh reroute event восстанавливается ≤ 800ms end-to-end без dropped call `-sim`
- Effort: 3 дня

### Sprint 4 · Trust hardening

**E4.1 · Session attestation preview (pre-silicon `-sim`, post-silicon real)**
- Файлы: `docs/PROOF_OF_FPGA_ADMIN_ATTEST.md`, `gen/rust/session_attest.rs`
- Deliverable: session establishment протокол где P203 узел отправляет **placeholder** signature (SHA3(bitstream) + node_id + nonce + Ed25519 pre-silicon signature) в admin PWA; на post-silicon — 3-of-3 Phi+Euler+Gamma chip signatures
- Acceptance: PWA отображает «Node identity: node-13 · Attestation: pre-silicon (Ed25519)» ИЛИ «post-silicon 3-of-3 verified» в зависимости от build; замена битстрима → attestation mismatch, PWA отключает write access
- Effort: 4 дня

## 6 · Три варианта сотрудничества для следующего лупа

Каждый вариант — self-contained, unblocking, executable в параллель разными actor'ами.

### Lane A · «PWA-first pragma» (fastest to first working PTT)

- **Scope:** Sprint 1 (E1.1, E1.2) + Sprint 2 (E2.1) + Sprint 3 (E3.2 без backend Opus)
- **Actor fit:** один fullstack Rust+TS разработчик, знакомый с WebRTC/Web Audio, iOS Safari quirks
- **Deliverable:** iPhone Safari-PWA работает как admin dashboard **и** browser-to-browser PTT через P203 relay (mesh просто forward'ит WebSocket messages), полностью в user-space без App Store
- **DEMO artefact:** видео (без монтажа) двух iPhone, каждый tethered к своему P203, mesh между P203 boards, PTT работает 3-hop
- **Cite:** [Apple PWA Add-to-Home-Screen](https://developer.apple.com/documentation/webkit) `-cite`, [Opus.js WASM](https://github.com/xiph/opus)
- **Effort:** 3 недели (1 dev)
- **Risk:** background audio на iOS Safari недоступен без CallKit; foreground-only ограничение для v0.1
- **Trinity rule:** admin trust = `-sim` (paranoia mode + local QR), attestation `-sim` до silicon

### Lane B · «Native iTAK-plugin style» (highest polish, longest path)

- **Scope:** Sprint 1 + native iOS app (Swift + Network.framework + Opus native + CallKit + PushKit) + Sprint 4
- **Actor fit:** iOS Swift developer + backend Rust developer, оба знают ATAK/iTAK plugin ecosystem
- **Deliverable:** native iOS app в TestFlight (не App Store сразу), background audio, mesh discovery через custom Bonjour service type, CallKit UI для PTT
- **DEMO artefact:** app в TestFlight link, working на 3 iPhones включая locked-screen incoming PTT
- **Cite:** [goTenna Pro iOS](https://apps.apple.com/it/app/gotenna-pro/id1482286139), [Apple Network.framework](https://developer.apple.com/documentation/network), [CallKit](https://developer.apple.com/documentation/callkit)
- **Effort:** 2-3 месяца (2 devs), $99/год Apple Developer Program
- **Risk:** App Store review для «off-grid mesh comms» app может быть отклонён по guideline 5.2.5 (заявлено tactical use); TestFlight обходит но ограничивает 10k testers max
- **Trinity rule:** после silicon (2026-12-16+) можно рекламировать «chip-attested off-grid comms», до — «open-source mesh with device-DNA attestation» (SACHa-style, см. Track B skill)

### Lane C · «Split brain» (parallel lanes A и B, hedge)

- **Scope:** Lane A + Lane B стартуют одновременно; Lane A даёт demo через 3 недели, Lane B — через 2-3 месяца; знания перетекают (RTP framing, jitter buffer, Opus wrapper — общие между Lane A и B; iOS-native код — только Lane B)
- **Actor fit:** 1 fullstack dev на Lane A, 1 iOS + 1 Rust dev на Lane B, координация через shared spec `docs/PTT_PROTOCOL_SPEC.md`
- **Deliverable:** Lane A demo на Hub71+ submission (Sept 2026), Lane B production candidate для post-silicon launch
- **DEMO artefact:** двухступенчатый: Lane A на 3 недели, Lane B на 2 месяца
- **Cite:** all above
- **Effort:** 2-3 dev-месяца распределённо
- **Risk:** координация; Lane A может «съесть» Lane B если PWA окажется достаточно
- **Trinity rule:** оба Lane соблюдают `-sim`/`-cite` дисциплину; никаких chip-attestation claims до silicon

### Рекомендация

**Lane A** первая. Причина: покрывает `-sim` от начала до конца, никаких зависимостей от App Store, никаких зависимостей от silicon, честно демонстрирует «voice mesh works» с самой дешёвой стороны рынка (любой iPhone, любой оператор). Lane B — если Lane A демонстрация подтверждает market fit.

## 7 · Boundary — что эта волна не делает

- Не строит iOS native app. Только PWA — на этой волне.
- Не заявляет chip-attestation до silicon 2026-12-16. Всё pre-silicon = `-sim`.
- Не гарантирует video, только audio PTT. Video требует M3 goodput measurement + отдельный milestone.
- Не решает background audio на iOS без CallKit; foreground-only для v0.1.
- Не заменяет ATAK/iTAK. Мы можем со временем стать iTAK-plugin backend, но не в этой волне.
- Не устанавливает MFi accessory certification. Работает только через standard iOS APIs (USB tether + Safari PWA + Bonjour).
- Не касается FPGA bitstream — LCD/camera bring-up идёт в параллельном треке (P203 Mini display этой волны не касается, только PS-Linux side).

## 8 · Merge-order dependency

```
PR #79 (M2 TUN spec)               ────┐
                                       ├── E1.1 topology doc (this wave)
PR #65/#63 (Noise handshake)       ────┤
                                       ├── E1.2 TUN + IP-over-mesh
PR #57 (M2 hardware milestones)    ────┘
                                              │
                                              ├── E2.1 PWA + mDNS
                                              ├── E2.2 Admin API + mTLS
                                              ├── E3.1 Opus/RTP framing
                                              ├── E3.2 Browser PTT
                                              ├── E3.3 Adaptive jitter buffer
                                              └── E4.1 Session attestation (`-sim`)
```

E1.1 (topology doc) — единственная задача, которая может стартовать **сейчас** без merge других PR. Именно её и создаёт этот draft PR как first tangible artifact.

## 9 · Trust ledger

| Утверждение | Method | Trust class |
|---|---|---|
| Zynq-7020 имеет GEM Ethernet controller | UG585 Xilinx TRM | cited |
| `trios_meshd` работает на 3 boards | git-log / PR #57 | structural |
| iPhone Personal Hotspot exposes ethernet-class device | ArchWiki libimobiledevice | cited |
| iOS 14+ требует NSLocalNetworkUsageDescription | Apple Developer Forums | cited |
| Meshtastic Codec2 не работает на sub-1GHz LoRa | White Hat / Meshtastic docs | cited |
| Opus PLC терпит ~120ms | jitter.is blog | cited |
| ITU G.114 latency budget <150ms | Cisco docs | cited |
| Opus decoder ~10 MHz per stream на Cortex-A9 | RFC 6716 + Opus benchmarks | cited but not personally measured |
| Mesh reroute ≤ 5s | skill `tri-net-m2-m4-workflow` M4 gate spec | `-sim` (measured on 3 boards, PR #57) |
| Mouth-to-ear latency 2-hop mesh ≤ 300ms | projection | `-sim` |

phi^2 + phi^-2 = 3
