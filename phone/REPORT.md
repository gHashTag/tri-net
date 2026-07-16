# Phone App для видео связи через TRI-NET mesh — Отчёт

## 1. СЛАБЫЕ МЕСТА ЗАДАЧИ

### Текущее состояние TRI-NET видео
| Компонент | Статус | Проблема |
|---|---|---|
| Video over radio (H.264) | ✅ `-sim` | Только host симуляция, не на железе |
| FPGA камера (OV5640) | ❌ Мёртва | Кристалл 24MHz на AN5642 не работает |
| Phone endpoint | ❌ Не существует | Нет app, нет протокола phone↔mesh |
| Display endpoint | ❌ Только CLI | Нет GUI для просмотра видео |
| Camera capture | ❌ Нет | Phone camera = альтернатива мёртвой OV5640 |

### Главная слабость: нет user-facing endpoint
Mesh работает board-to-board. Но **пользователь не может увидеть видео** — нет display, нет phone, нет монитора на дрон.

**Phone = решение:** смартфон как camera + display + codec endpoint.

---

## 2. КОНКУРЕНТЫ

| Продукт | Video | Phone App | Mesh | Open Source | Price |
|---|---|---|---|---|---|
| [Meshtastic](https://meshtastic.org/) | ❌ | ✅ (Flutter) | ✅ LoRa | ✅ | $30 |
| [Signal](https://signal.org/) | ✅ | ✅ | ❌ (central) | ✅ | Free |
| [Persistent MPU5](https://persistent.com/) | ✅ | ✅ (Android) | ✅ mil | ❌ | $4000+ |
| [Rajant](https://rajant.com/) | ✅ | ❌ | ✅ industrial | ❌ | $$$ |
| [Meshmerize](https://meshmerize.net/) | ✅ | ❌ | ✅ drone | ❌ | commercial |
| **TRI-NET** | **✅ H.264** | **⚠️ TODO** | **✅ FPGA 5.8GHz** | **✅ Apache 2.0** | **$200 BOM** |

**TRI-NET ниша:** единственный open-source FPGA mesh + phone video endpoint + military crypto.

---

## 3. ДЕКОМПОЗИРОВАННЫЙ ПЛАН

### Архитектура
```
[Phone Camera] → H.264 → UDP → [P203 Mini mesh node] → 5.8GHz radio → [P203 Mini] → UDP → [Phone Display]
```

Phone подключается к P203 Mini через WiFi. P203 Mini работает как mesh relay.

### E1: UDP Loopback (2-4 часа)
- [x] Phone app skeleton (Flutter) создан: `/Users/ssdm4/Desktop/PROJECTS/CLAUDE/tri-net-phone/`
- [ ] UDP socket: phone → P203:5000
- [ ] P203 `trios_meshd` UDP bridge mode
- [ ] Phone: UDP receive → display
- **Gate:** frame roundtrips phone→mesh→phone

### E2: Real Camera (4-6 часов)
- [ ] Phone camera capture (Flutter camera plugin)
- [ ] H.264 hardware encode (MediaRecorder/AVFoundation)
- [ ] Fragment H.264 into 70-byte chunks (matching vstream VFRAG)
- [ ] Phone display: H.264 decode → texture
- **Gate:** live video on phone screen

### E3: Two-Phone via Mesh (6-8 часов)
- [ ] Phone A: camera → mesh
- [ ] Phone B: mesh → display
- [ ] Bidirectional (both directions simultaneously)
- **Gate:** live video call through mesh

### E4: Multi-hop (8-10 часов)
- [ ] Phone A → node1 → node2 → node3 → Phone B
- [ ] Latency measurement
- [ ] Reed-Solomon protection for key frames (existing vstream.rs)
- **Gate:** video through 2+ hops

---

## 4. РЕАЛИЗАЦИЯ

### Создано в этой сессии:
- `/Users/ssdm4/Desktop/PROJECTS/CLAUDE/tri-net-phone/` — Flutter app skeleton
- `lib/main.dart` — UDP socket + UI (connect, send/receive test frames)
- `PLAN.md` — полный план с этапами E1-E4

### Что нужно сделать дальше:
1. `flutter create .` в `tri-net-phone/` (генерация Android/iOS платформы)
2. Добавить dependencies: `camera`, `flutter_webrtc`
3. Реализовать H.264 capture → UDP отправку
4. P203: добавить UDP bridge mode в `trios_meshd`

---

## 5. ТРИ ВАРИАНТА СОТРУДНИЧЕСТВА

### Вариант A: Phone-First (приоритет video на phone)
**Идея:** Забросить FPGA камеру (мёртвый кристалл). Phone = camera + display. FPGA = radio mesh relay.

**Плюсы:**
- Phone camera работает гарантированно (не нужно чинить AN5642)
- Video codec на phone (аппаратный H.264 encoder)
- Display на phone (не нужно LCD на FPGA)
- Быстрый результат: 2-4 часа до первого видео

**Минусы:**
- Phone не "в mesh" на уровне radio — только через WiFi gateway
- Задержка: phone → WiFi → P203 → radio → P203 → WiFi → phone

### Вариант B: FPGA-First (починить камеру)
**Идея:** Найти рабочий camera модуль. Использовать FPGA для encode + LCD для display.

**Плюсы:**
- Полностью автономный (нет phone зависимости)
- FPGA = camera + encode + radio + LCD display
- Military-grade: нет гражданского phone в loop

**Минусы:**
- AN5642 модуль мёртв (оба сенсора)
- Нужно покупать новый camera модуль
- Нет H.264 encoder на Artix-7 (только raw pixel stream)

### Вариант C: Hybrid (FPGA radio + Phone UI)
**Идея:** FPGA = radio mesh + LCD display. Phone = camera capture + control UI.

**Плюсы:**
- LCD на FPGA уже работает (color bars доказано)
- Phone camera = backup если FPGA камера не работает
- Phone = control panel (mesh status, routing table, etc.)
- Best of both worlds

**Минусы:**
- Сложнее архитектура (phone + FPGA coordination)
- Video: phone encode → mesh → FPGA decode → LCD (нужен H.264 decoder на FPGA)

### Рекомендация

**Вариант A (Phone-First)** — самый быстрый путь к работающему видео:
1. Phone camera работает (100% гарантия)
2. Video codec на phone (аппаратный)
3. FPGA = dumb radio relay (не нужно кодек/камера/LCD)
4. 2-4 часа до первого видео через mesh

`phi^2 + phi^-2 = 3`
