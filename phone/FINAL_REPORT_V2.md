# TRI-NET Phone Video Mesh — Финальный отчёт v2

## 1. СЛАБЫЕ МЕСТА

### Критические блокеры

| # | Проблема | Влияние | Статус | Решение |
|---|---|---|---|---|
| 1 | **AN5642 камера мертва** (оба сенсора, PCLK=0) | Нет video source с FPGA | ❌ Hardware | Замена модуля ИЛИ phone camera |
| 2 | **App не запускается на iPhone** (signing) | Нет теста на реальном устройстве | ❌ PLA agreement | Принять в Apple Developer portal |
| 3 | **Нет H.264 decode** на phone | Приходящее видео не отображается | ❌ TODO | VideoToolbox VTDecompressionSession |
| 4 | **UDP bridge не тестирован** на P203 | Mesh relay не проверен | ⚠️ Код готов | Прошить P203 + тест |
| 5 | **Mesh topology = mock** | Не реальные данные | ⚠️ Код готов | TOPO_REQ/RESP через meshd |

### Архитектурные слабости

| Проблема | Решение |
|---|---|
| Phone → WiFi → P203 → radio = 3 hops уже до radio | Minimize WiFi latency, consider USB tethering |
| H.264 encode latency на phone (~50ms) | Hardware encoder already used (VideoToolbox) |
| UDP unreliable on WiFi | FEC (Reed-Solomon) already in vstream.rs |
| No congestion control | Best-effort (acceptable for walkie-talkie UX) |
| Phone battery drain (encode + UDP) | Adaptive bitrate based on link quality |

## 2. КОНКУРЕНТЫ

### Прямые конкуренты (mesh + video + phone)

| Продукт | Video | Phone App | Mesh Radio | Open Source | Цена | Ссылка |
|---|---|---|---|---|---|---|
| [Meshtastic](https://meshtastic.org) | ❌ текст | ✅ Flutter | ✅ LoRa 915MHz | ✅ | $30 | Google Play |
| [Signal](https://signal.org) | ✅ E2E | ✅ native | ❌ central server | ✅ | Free | App Store |
| [Persistent MPU5](https://persistent.com) | ✅ H.264 | ✅ Android | ✅ mil mesh | ❌ | $4000+ | — |
| [Rajant](https://rajant.com) | ✅ | ❌ | ✅ Kinetic Mesh | ❌ | $$$ | — |
| [Meshmerize](https://meshmerize.net) | ✅ | ❌ | ✅ drone mesh | ❌ | commercial | — |
| [OpenIPC](https://openipc.org) | ✅ H.264 | ❌ | ❌ Wi-Fi | ✅ | $50 | — |
| [RosettaDrone](https://github.com/RosettaDrone/rosettadrone) | ✅ | ✅ Android | ❌ MAVLink | ✅ | Free | GitHub |

### TRI-NET позиционирование

```
                    VIDEO capable
                         │
         Signal ◆        │        ◆ MPU5 ($4000+)
         (central)       │        Rajant ($$$)
                         │
NO mesh ◄────────────────┼────────────────► FULL mesh
                         │
    RosettaDrone ◆       │       ◆ TRI-NET ($200 BOM)
    (MAVLink only)       │       Meshtastic ($30, no video)
                         │
                    TEXT only
```

**TRI-NET уникальная ниша:** Open-source FPGA mesh + iOS video app + military crypto + $200 BOM.

## 3. ДЕКОМПОЗИРОВАННЫЙ ПЛАН

### Phase 1: Phone App работает локально (1 день)

| Step | Task | Статус |
|---|---|---|
| 1.1 | Модульная система (5 файлов) | ✅ Готово |
| 1.2 | Camera capture + preview | ✅ Готово |
| 1.3 | H.264 encode (VideoToolbox) | ✅ Готово |
| 1.4 | UDP send/receive | ✅ Готово |
| 1.5 | Mesh topology map (real-time) | ✅ Готово (mock data) |
| 1.6 | H.264 decode (receive + display) | ⬜ TODO |
| 1.7 | App signing (real iPhone) | ⬜ Apple PLA |
| 1.8 | Local loopback test (phone ↔ Mac UDP echo) | ⬜ TODO |

### Phase 2: Mesh Integration (2-3 дня)

| Step | Task | Статус |
|---|---|---|
| 2.1 | trios_meshd_video.rs на P203 | ✅ Код готов |
| 2.2 | Phone → P203 UDP bridge test | ⬜ Hardware |
| 2.3 | P203 → P203 radio relay test | ⬜ Hardware |
| 2.4 | Real topology query (TOPO_REQ/RESP) | ⬜ Replace mock |
| 2.5 | End-to-end: PhoneA → P203 → radio → P203 → PhoneB | ⬜ Demo |

### Phase 3: Production (1-2 недели)

| Step | Task |
|---|---|
| 3.1 | Adaptive bitrate (link quality → encode params) |
| 3.2 | FEC integration (Reed-Solomon from vstream.rs) |
| 3.3 | Android port (Skip.tools or Kotlin) |
| 3.4 | App Store submission |
| 3.5 | Field test (outdoor, real range) |

## 4. ЧТО РЕАЛИЗОВАНО

### iOS App (модульная, 5 файлов, 760 строк)

| Файл | Строк | Назначение |
|---|---|---|
| `App.swift` | 12 | @main entry point |
| `ViewModel.swift` | 83 | State, permissions, start/stop |
| `Views.swift` | 262 | Home + Streaming + Settings screens |
| `MeshMapView.swift` | 228 | Real-time topology map |
| `VideoPipeline.swift` | 175 | Camera + H.264 + UDP |

### t27 Specs (spec-first golden pipeline)

| Spec | Тестов | Инвариантов | Назначение |
|---|---|---|---|
| `video_bridge.t27` | 21 | 3 | Fragment format, ports, seq |
| `mesh_topology.t27` | 20 | 4 | Node status, ETX→quality, topology query |

### Mesh Daemon

| Файл | Строк | Назначение |
|---|---|---|
| `trios_meshd_video.rs` | 280 | UDP ↔ mesh radio bridge |

### FPGA (LCD + Camera диагностика)

| Достижение | Доказательство |
|---|---|
| LCD работает (color bars) | lcd_official_port.bit ✅ |
| LCD solid RED | lcd_red_exact.bit ✅ |
| Framebuffer BRAM inference (64 RAMB36E1) | lcd_cam_bram.bit ✅ |
| Camera I2C config (251 регистр) | LED2=ON ✅ |
| Camera PCLK/HREF | ❌ Мёртв (AN5642 кристалл) |

## 5. ТРИ ВАРИАНТА СОТРУДНИЧЕСТВА

### Вариант A: Phone-First MVP (рекомендуется, 2-3 дня)

**Цель:** Работающее видео PhoneA → P203 → radio → P203 → PhoneB.

**Что нужно:**
1. Принять Apple PLA agreement (10 минут)
2. Запустить app на iPhone (1 час)
3. Прошить 2× P203 с trios_meshd_video (1 час)
4. Тест Phone→P203→P203→Phone (2 часа)
5. Записать demo (30 минут)

**Gate:** Живое видео между двумя телефонами через mesh radio.
**Риск:** WiFi latency на P203.

**Почему:** Самый быстрый путь к demo. Phone camera гарантированно работает. Mesh уже доказан. 2-3 дня до результата.

### Вариант B: FPGA Camera Repair (1-2 недели)

**Цель:** Заменить AN5642 модуль, получить camera→LCD pipeline.

**Что нужно:**
1. Купить новый AN5642 или single OV5640 модуль ($15-30)
2. Подключить к AX7203 J13
3. Использовать lcd_cam_bram.bit (framebuffer готов!)
4. Camera → BRAM → LCD pipeline

**Gate:** Live camera на LCD без phone.
**Риск:** Новый модуль может тоже не работать.

**Почему:** Полностью автономная система (нет phone зависимости). Но дольше и дороже.

### Вариант C: Hybrid Platform (2-3 недели)

**Цель:** Phone = camera + display. FPGA = radio relay + LCD mirror.

**Что нужно:**
1. Phone camera → H.264 → mesh (Вариант A)
2. На FPGA: decode H.264 from mesh → LCD
3. Или: raw pixel bypass (phone → JPEG → mesh → LCD)

**Gate:** Phone AND FPGA LCD показывают video одновременно.
**Риск:** H.264 decode на Artix-7 сложен.

**Почему:** Best of both worlds. Но самый сложный и долгий.

---

## Рекомендация

**Вариант A (Phone-First MVP)** — 3 дня до demo видео.

`phi^2 + phi^-2 = 3`
