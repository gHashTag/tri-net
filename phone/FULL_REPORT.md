# TRI-NET Phone Video Mesh — ПОЛНЫЙ ОТЧЁТ

## 1. СЛАБЫЕ МЕСТА ЗАДАЧИ

| Проблема | Влияние | Статус | Решение |
|---|---|---|---|
| FPGA камера мёртва (AN5642) | Нет video source с FPGA | ❌ Оба сенсора PCLK dead | Phone camera = альтернатива |
| Нет phone endpoint | Пользователь не видит видео | ❌ Нет app | **TriNetVideo iOS app создан** |
| Нет UDP bridge | Phone не подключён к mesh | ❌ Нет bridge | **trios_meshd_video.rs создан** |
| Нет video display | Только CLI | ❌ | SwiftUI display в phone app |
| Нет multi-hop video | Только 1 hop | ⚠️ vstream.rs готов (-sim) | E3: multi-hop через Playout |

## 2. КОНКУРЕНТЫ

| Продукт | Video | Phone App | Mesh | Open Source | Цена | Ссылка |
|---|---|---|---|---|---|---|
| Meshtastic | ❌ | ✅ Flutter | ✅ LoRa | ✅ | $30 | [meshtastic.org](https://meshtastic.org) |
| Signal | ✅ | ✅ | ❌ central | ✅ | Free | [signal.org](https://signal.org) |
| MPU5 (Persistent) | ✅ | ✅ Android | ✅ mil | ❌ | $4000+ | [persistent.com](https://persistent.com) |
| Rajant Kinetic Mesh | ✅ | ❌ | ✅ industrial | ❌ | $$$ | [rajant.com](https://rajant.com) |
| Meshmerize | ✅ | ❌ | ✅ drone | ❌ | commercial | [meshmerize.net](https://meshmerize.net) |
| RosettaDrone | ✅ | ✅ Android | ❌ MAVLink | ✅ | Free | [github.com/rosettadrone](https://github.com/RosettaDrone/rosettadrone) |
| OpenIPC | ✅ | ❌ | ❌ Wi-Fi | ✅ | $50 | [OpenIPC](https://openipc.org) |
| **TRI-NET** | **✅ H.264** | **✅ iOS (создан)** | **✅ FPGA 5.8GHz** | **✅ Apache 2.0** | **$200 BOM** | **—** |

**TRI-NET уникальная ниша:** единственный open-source FPGA mesh + iOS video app + military crypto.

## 3. ДЕКОМПОЗИРОВАННЫЙ ПЛАН

### Этапы (выполнено ✅ / pending ⬜)

| Этап | Описание | Статус | Время |
|---|---|---|---|
| E0 | Phone app skeleton (SwiftUI) | ✅ Готово | — |
| E0 | H.264 encoder (VideoToolbox) | ✅ Готово | — |
| E0 | UDP transport (Network.framework) | ✅ Готово | — |
| E0 | UI + metrics | ✅ Готово | — |
| E1 | UDP bridge (trios_meshd_video) | ✅ Готово | — |
| E2 | Phone → P203 → P203 → Phone loopback | ⬜ Test on hardware | 2ч |
| E3 | Real camera → H.264 → mesh → display | ⬜ Camera integration | 4ч |
| E4 | Two-phone video call through mesh | ⬜ Bidirectional | 6ч |
| E5 | Multi-hop (2+ hops) | ⬜ Playout buffer | 8ч |

### Архитектура
```
[iPhone Camera] → H.264 encode → UDP:7000 → [P203 Mini: trios_meshd_video]
                                                    ↓
                                              fragment (70B chunks)
                                                    ↓
                                              mesh radio (5.8GHz)
                                                    ↓
                                              [P203 Mini: trios_meshd_video]
                                                    ↓
                                              reassemble + Playout
                                                    ↓
                                              UDP:7001 → [iPhone Display]
```

## 4. ЧТО СОЗДАНО

### iOS App (505 строк)
**`/Users/ssdm4/Desktop/PROJECTS/CLAUDE/tri-net-phone/TriNetVideo/TriNetVideoApp.swift`**

| Компонент | Технология | Lines |
|---|---|---|
| H.264 Encoder | VideoToolbox VTCompressionSession | 70 |
| Camera Capture | AVFoundation AVCaptureSession | 40 |
| UDP Transport | Network.framework NWConnection | 35 |
| View Model | Combine + ObservableObject | 80 |
| SwiftUI UI | Dark mode, metrics, status | 120 |
| Permissions | Camera access handling | 20 |

Features:
- Camera permission auto-request
- H.264 hardware encode: 480×272 @ 15fps, 200kbps, Baseline 3.0
- UDP transport with auto-reconnect
- Real-time metrics: TX/RX frames, KB/s
- Connection status indicator
- IP persistence (UserDefaults)
- Dark mode optimized for field use

### UDP Bridge Daemon (280 строк)
**`/Users/ssdm4/Desktop/PROJECTS/CLAUDE/tri-net-phone/src/bin/trios_meshd_video.rs`**

| Компонент | Что делает |
|---|---|
| Phone→Mesh thread | recv H.264 → fragment → mesh send |
| Mesh→Phone thread | mesh recv → reassemble → UDP send to phone |
| VSTREAM fragmenter | 70-byte chunks with seq/idx/count header |
| SimpleRouter | Peer routing (simplified, no crypto for bridge testing) |
| Config parser | Same format as trios_meshd (id/listen/peer) |

Environment variables:
```
TRIOS_VIDEO_IN=0.0.0.0:7000    # phone sends H.264 here
TRIOS_VIDEO_OUT=phone_ip:7001  # mesh sends reassembled video here  
TRIOS_VIDEO_DST=12             # destination mesh node
```

### Project structure
```
tri-net-phone/
├── TriNetVideo.xcodeproj/       # Xcode project
├── TriNetVideo/
│   ├── TriNetVideoApp.swift     # 505 lines — iOS app
│   ├── Info.plist               # Camera + network permissions
│   └── Assets.xcassets/         # App icon
├── src/
│   └── bin/
│       └── trios_meshd_video.rs # 280 lines — UDP bridge daemon
├── PLAN.md                      # E1-E4 roadmap
├── OPTIONS.md                   # Cross-platform comparison
└── REPORT.md                    # This report
```

## 5. ТРИ ВАРИАНТА СОТРУДНИЧЕСТВА ДЛЯ СЛЕДУЮЩЕГО ЛУПА

### Вариант A: Phone-First Demo (рекомендуется)
**Цель:** Работающее video через mesh на двух телефонах за 1 день.

**Что делать:**
1. Прошить P203 Mini (2 шт.) с `trios_meshd_video`
2. Подключить телефоны к P203 по WiFi
3. Запустить TriNetVideo app на обоих
4. Phone A → P203 #1 → radio → P203 #2 → Phone B
5. Записать демо видео

**Время:** 4-6 часов на железе
**Gate:** живое видео с камерой в реальном времени через mesh
**Риск:** WiFi на P203 может быть медленным

### Вариант B: FPGA Camera Repair
**Цель:** Починить AN5642 (заменить кристалл 24MHz или модуль целиком).

**Что делать:**
1. Купить новый AN5642 или OV5640 модуль
2. Подключить к AX7203
3. Использовать lcd_cam_bram.bit (framebuffer готов — 64 RAMB36E1!)
4. Camera → BRAM → LCD pipeline

**Время:** 2-3 дня (заказ + доставка + тест)
**Gate:** live camera на LCD без phone
**Риск:** новый модуль может тоже не работать

### Вариант C: Hybrid Platform
**Цель:** Phone = camera + display, FPGA = radio relay + LCD mirror.

**Что делать:**
1. Phone camera → H.264 → mesh → Phone display (Вариант A)
2. На FPGA стороне: decode H.264 from mesh → LCD display
3. Нужен H.264 decoder на Artix-7 (сложно)
4. Или: raw pixel bypass (phone → JPEG frames → mesh → LCD)

**Время:** 1-2 недели
**Gate:** phone AND FPGA LCD показывают video одновременно
**Риск:** H.264 decode на Artix-7 может не получиться

### Рекомендация

**Вариант A (Phone-First Demo)** — самый быстрый путь к работающему видео:
- Phone camera = гарантированно работает
- H.264 encode = аппаратный (VideoToolbox)
- UDP bridge = написан
- Mesh = доказан (3 платы converged)
- 4-6 часов до первого живого видео

`phi^2 + phi^-2 = 3`
