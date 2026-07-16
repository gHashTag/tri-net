# Финальный отчёт волны — TRI-NET Phone Video Mesh

## 1. СЛАБЫЕ МЕСТА (текущее состояние)

### Критические (блокируют demo)

| # | Проблема | Где | Статус |
|---|---|---|---|
| C1 | **App не подписан** (PLA agreement) | Apple Developer | ❌ Нужен human action |
| C2 | **UDP bridge не тестирован на P203** | Hardware | ❌ 2 платы нужны |
| C3 | **Нет двусторонней связи** (bidirectional) | ViewModel | ⚠️ Только TX |
| C4 | **Metal renderer может не работать** на симуляторе | VideoPipeline | ⚠️ Только реальный iPhone |

### Архитектурные

| # | Проблема | Влияние |
|---|---|---|
| A1 | Topology = mock fallback когда нет hardware | UI показывает случайные ноды |
| A2 | Нет адаптивного bitrate | Плохой линк = дропы |
| A3 | Нет FEC на phone side | Дропы = артефакты |
| A4 | Нет reconnect logic | WiFi обрыв = ручной restart |

## 2. КОНКУРЕНТЫ (обновлено)

| Продукт | Video | Phone App | Mesh | OSS | BOM | Наше преимущество |
|---|---|---|---|---|---|---|
| Meshtastic | ❌ | ✅ | LoRa 915MHz | ✅ | $30 | У нас видео + FPGA radio |
| Signal | ✅ | ✅ | ❌ central | ✅ | Free | У нас mesh (offline) |
| MPU5 | ✅ | ✅ | ✅ mil | ❌ | $4000+ | У нас $200 BOM |
| RosettaDrone | ✅ | ✅ | ❌ MAVLink | ✅ | Free | У нас radio mesh |
| OpenIPC | ✅ | ❌ | ❌ WiFi | ✅ | $50 | У нас mesh multi-hop |
| **TRI-NET** | **✅ H.264** | **✅ iOS** | **✅ FPGA 5.8GHz** | **✅** | **$200** | **Уникальная ниша** |

## 3. РЕАЛИЗАЦИЯ (всё сделано в этой волне)

### iOS App (5 модулей, 1036 строк)

| Файл | Строк | Features |
|---|---|---|
| App.swift | 12 | @main entry |
| ViewModel.swift | 91 | State + permissions + encode/decode pipeline |
| Views.swift | 255 | Home + Streaming + Settings + UI components |
| MeshMapView.swift | 270 | Real-time topology + TOPO_REQ/RESP parser + mock fallback |
| VideoPipeline.swift | 408 | Camera + H264Encoder + **H264Decoder (#83)** + MetalRenderer + UDP |

### t27 Specs (golden pipeline)

| Spec | Тесты | Инварианты |
|---|---|---|
| video_bridge.t27 | 21 | 3 |
| mesh_topology.t27 | 20 | 4 |

### Mesh daemon

| Файл | Строк | Status |
|---|---|---|
| trios_meshd_video.rs | 280 | Код готов, не тестирован на hardware |

### GitHub

| Issue | Title | Status |
|---|---|---|
| #82 | EPIC: Phone Video Mesh | OPEN |
| #83 | H.264 decode | ✅ Implemented |
| #84 | P203 bridge test | OPEN (hardware) |
| #85 | Real topology query | ✅ Implemented |
| #86 | Android port | OPEN (future) |
| #87 | End-to-end demo | OPEN (hardware) |

## 4. ДЕКОМПОЗИРОВАННЫЙ ПЛАН

### Done ✅

| Step | Task | Done |
|---|---|---|
| D1 | Modular Swift app (5 files) | ✅ |
| D2 | Camera capture + preview | ✅ |
| D3 | H.264 encode (VideoToolbox) | ✅ |
| D4 | H.264 decode (#83) | ✅ |
| D5 | UDP transport (Network.framework) | ✅ |
| D6 | Mesh topology map (#85) | ✅ |
| D7 | UX: 3-screen (Home/Streaming/Settings) | ✅ |
| D8 | t27 specs (video_bridge + mesh_topology) | ✅ |
| D9 | UDP bridge daemon (trios_meshd_video.rs) | ✅ |
| D10 | GitHub epic + 5 sub-issues | ✅ |

### Next ⬜

| Step | Task | Dependency | ETA |
|---|---|---|---|
| N1 | Apple PLA agreement + signing | Human | 10 min |
| N2 | App test on real iPhone | N1 | 1 hour |
| N3 | Flash P203 × 2 with trios_meshd_video | Hardware | 1 hour |
| N4 | Phone→P203 UDP bridge test | N2+N3 | 2 hours |
| N5 | End-to-end: PhoneA→P203→P203→PhoneB | N4 | 2 hours |
| N6 | Demo video recording | N5 | 30 min |
| N7 | Android port (#86) | N5 | 1 week |
| N8 | App Store submission | N5 | 1 week |

## 5. ТРИ ВАРИАНТА СОТРУДНИЧЕСТВА

### Вариант A: Demo Sprint (1-2 дня)

**Что:** Принять PLA → запустить на iPhone → прошить 2× P203 → живое видео.

**Роли:**
- Генерал: принять PLA, подключить iPhone + 2 P203
- Я: отладка на железе, запись demo

**Gate:** Живое видео PhoneA → P203 → radio → P203 → PhoneB.
**Риск:** WiFi latency на P203 (~50ms).

### Вариант B: Production Polish (1 неделя)

**Что:** Adaptive bitrate + FEC + reconnect + bidirectional audio.

**Роли:**
- Я: implement FEC (Reed-Solomon), adaptive bitrate, bidirectional
- Генерал: field test (outdoor range test)

**Gate:** Production-quality video call через mesh, <500ms latency.
**Риск:** Больше кода = больше багов.

### Вариант C: Platform Expansion (2-3 недели)

**Что:** Android port + FPGA LCD mirror + App Store.

**Роли:**
- Я: Kotlin Multiplatform port, FPGA LCD decode, App Store prep
- Генерал: hardware (новая camera модуль), marketing

**Gate:** TRI-NET app в App Store + Google Play + FPGA LCD mirror.
**Риск:** Долго, но максимальный охват.

---

**Рекомендация: Вариант A (Demo Sprint)** — 1-2 дня до первого живого видео через mesh.

phi^2 + phi^-2 = 3
