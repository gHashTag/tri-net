# ОТЧЁТ: Видеосвязь Mac ↔ iPhone через mesh — детальный разбор задачи

> Статус на 2026-07-16. Пути в этом отчёте указаны до консолидации в репо tri-net;
> актуальный корень проекта: `tri-net/phone/` (бывш. `/Users/ssdm4/Desktop/PROJECTS/CLAUDE/tri-net-phone/`).

## 1. ЦЕЛЬ

Создать видеозвонок между Mac и iPhone в одной WiFi сети (192.168.1.x). Mac и iPhone в одной локальной сети, IP:
- **Mac**: 192.168.1.105
- **iPhone (neuro_coder)**: 192.168.1.103

Поток данных: Камера → H.264 encode (VideoToolbox) → UDP пакеты → сеть → UDP приём → H.264 decode (VideoToolbox) → отображение на экране.

Двунаправленный: каждый устройство одновременно отправляет и принимает видео.

## 2. АРХИТЕКТУРА

### 2.1 Приложения

**Три приложения:**
1. **TriNetMonitor** (macOS, SwiftUI) — главное desktop приложение. Содержит 3 таба: Network (топология сети), RTI Heatmap, Video Call. Находится в `phone/desktop/`
2. **TriNetVideo** (iOS, SwiftUI) — мобильное приложение для видеозвонков. Находится в `phone/TriNetVideo/`
3. **TriNetVideo** (macOS, SwiftUI) — отдельное desktop видео-приложение. Находится в `phone/desktop/TriNetVideo/`

### 2.2 Файлы

**iOS приложение (TriNetVideo):**
- `App.swift` — entry point, `@main`
- `VideoPipeline.swift` — Camera capture + H264Encoder + H264Decoder + BSDTransport (NWConnection+NWListener)
- `ViewModel.swift` — StreamViewModel, оркестратор
- `Views.swift` — HomeView (FaceTime UX), CallScreen, SettingsView

**macOS приложение (TriNetMonitor) — Video Call таб:**
- `TriNetMonitor.swift` — главное приложение, табы: Network / RTI Heatmap / Video Call
- `VideoCallTab.swift` — VideoEngine (BSD socket приём), H264DecoderShared, VideoDisplayView, VideoCallTab (UI)
- `RTIHeatmap.swift` — RTI heatmap (работает частично)

### 2.3 Транспорт

UDP, порт **7000** для обоих направлений.
- iPhone: `NWConnection` отправляет на Mac:7000, `NWListener` слушает :7000
- Mac: BSD socket `recvfrom` на :7000 (blocking, background DispatchQueue)

## 3. ЧТО РАБОТАЕТ ✅

1. **iPhone отправляет видео** — доказано Python bridge тестом: 500+ H.264 NAL пакетов получено
2. **Mac BSD socket получает данные** — доказано: `recvfrom` возвращает пакеты, `netstat` показывает 770614+ пакетов
3. **Логи в UI работают** — BG → NSLock → Timer flush → @Published (без freeze)
4. **SPS/PPS extraction из formatDescription** — код написан, компилируется
5. **Mac не зависает** — после исправления threading (локальные переменные вместо @Published в background thread)

## 4. ЧТО НЕ РАБОТАЕТ ❌ — ГЛАВНАЯ ПРОБЛЕМА

**H.264 декодер на Mac НЕ декодирует видео.**

### Симптомы из логов:

```
🎉 FIRST PACKET! 35B — iPhone sending!
📦 NAL type 6 = SEI, 35B          ← metadata
📦 NAL type 1 = P-frame, 789B     ← video data
📦 NAL type 5 = I-frame, 4594B    ← KEY frame
📥 pkt #1500 ...                   ← данные идут непрерывно
```

**НЕТ строки `🎬 FIRST FRAME DECODED!`** — callback декодера никогда не вызывается.

### Корневая причина:

**iPhone НЕ отправляет SPS (NAL=7) и PPS (NAL=8) как отдельные пакеты.**

Без SPS+PPS декодер `VTDecompressionSession` не может быть создан:

```swift
CMVideoFormatDescriptionCreateFromH264ParameterSets(...) // требует SPS+PPS
VTDecompressionSessionCreate(formatDescription: desc, ...) // требует formatDescription
```

### Почему SPS/PPS не отправляются:

iPhone H264Encoder `process()` извлекает NAL units из `CMSampleBuffer`. SPS/PPS содержатся в `CMVideoFormatDescription` (метаданные), а НЕ в `CMBlockBuffer` (данные кадра). Код для извлечения SPS/PPS через `CMVideoFormatDescriptionGetH264ParameterSetAtIndex` **написан, но iPhone app НЕ был пересобран** (требует Cmd+R в Xcode GUI).

## 5. ВСЕ ПОПЫТКИ РЕШЕНИЯ

### Попытка 1: NWListener на macOS для приёма
**Результат:** NWListener на macOS 14+ требует entitlement, молча не биндится (IPv6 only).
**Фикс:** Заменили на BSD socket (AF_INET, SOCK_DGRAM, bind на 0.0.0.0:7000).
**Статус:** ✅ BSD socket работает

### Попытка 2: BSD socket non-blocking + usleep polling
**Результат:** App зависал. Причина: `@Published var pktCount += 1` в background thread → SwiftUI crash `Publishing changes from background threads is not allowed`.
**Фикс:** Локальные переменные в recvLoop, @Published обновления только через `DispatchQueue.main.async`.
**Статус:** ✅ Не зависает

### Попытка 3: Логи в UI через @Published
**Результат:** 100+ обновлений @Published в секунду → UI freeze.
**Фикс:** BG логи → NSLock → pendingLogs → Timer 0.3s flush → @Published.
**Статус:** ✅ Логи работают, не зависает

### Попытка 4: SPS/PPS extraction на iPhone
**Результат:** Код добавлен (`CMVideoFormatDescriptionGetH264ParameterSetAtIndex`), но iPhone не пересобран.
**Статус:** ⏳ Требует Cmd+R в Xcode

### Попытка 5: SPS/PPS extraction из I-frame на Mac
**Результат:** `extractSPSfromIFrame()` сканирует Annex-B bitstream. Но I-frame = один NAL, SPS/PPS внутри него отсутствуют.
**Статус:** ❌ Не работает

### Попытка 6: Hardcoded SPS/PPS (текущая)
**Результат:** Сгенерированы байты SPS для 480×272 Baseline 3.0. При получении P/I-frame без SPS/PPS — создаются вручную.
**Статус:** ⏳ Применена, но hardcoded SPS байты могут быть неточными. `CMVideoFormatDescriptionCreateFromH264ParameterSets` может вернуть ошибку.

### Попытка 7: NWConnection для отправки на Mac
**Результат:** Mac использует NWConnection для отправки видео на iPhone. Но данные не отправляются (камера на Mac не включена).
**Статус:** ❌ Mac камера не интегрирована

### Попытка 8: Standalone swiftc binary
**Результат:** swiftc binary не создаёт окно на macOS (нужен .app bundle).
**Статус:** ❌

### Попытка 9: Standalone Xcode project (RTIApp)
**Результат:** Компилируется, но окно не показывается.
**Статус:** ❌

## 6. ЧТО НУЖНО СДЕЛАТЬ

### Критическое (блокирует видео):
1. **Пересобрать iPhone app** с SPS/PPS extraction кодом (Cmd+R в Xcode)
2. **ИЛИ** использовать правильные hardcoded SPS/PPS байты (текущая попытка может быть с ошибкой в байтах)
3. **Проверить** что `CMVideoFormatDescriptionCreateFromH264ParameterSets` возвращает `noErr` — добавить лог статуса

### Для двусторонней связи:
4. **Добавить CameraCapture + H264Encoder на Mac** — Mac должен не только принимать, но и отправлять видео
5. **Mac камера**: `AVCaptureSession` → `VTCompressionSession` → BSD socket send на iPhone:7000

### Для UX:
6. **Логи на iPhone** — добавить панель логов в iOS Views.swift
7. **FaceTime-style controls** на обеих платформах

## 7. КЛЮЧЕВЫЕ ФАЙЛЫ

| Файл | Роль | Проблема |
|------|------|----------|
| `desktop/VideoCallTab.swift` | Mac приёмник + декодер | SPS/PPS не приходят, декодер не init |
| `TriNetVideo/VideoPipeline.swift` | iPhone камера + энкодер + транспорт | SPS/PPS extraction НЕ пересобран |
| `TriNetVideo/ViewModel.swift` | iPhone оркестратор | Порт 7000 (send+recv одинаковые) |
| `TriNetVideo/Views.swift` | iPhone UI | Нет логов, нужен Cmd+R |

## 8. ТЕХНИЧЕСКИЕ ДЕТАЛИ ДЛЯ ДРУГОГО АГЕНТА

### H.264 поток от iPhone (доказано логами):
- NAL=6 (SEI): 35B, metadata
- NAL=1 (P-frame): 600-2400B, видео данные
- NAL=5 (I-frame): 1453-4594B, KEY кадры каждые ~2 сек
- **NAL=7 (SPS): ОТСУТСТВУЕТ** ← корневая проблема
- **NAL=8 (PPS): ОТСУТСТВУЕТ** ← корневая проблема

### iPhone энкодер настройки:

```
Width: 480, Height: 272
Profile: H.264 Baseline 3.0 (profile_idc=66, level_idc=30)
Bitrate: 200 kbps
RealTime: true
MaxKeyFrameInterval: 10
MaxKeyFrameIntervalDuration: 0.5s
AllowFrameReordering: false
```

### Mac декодер pipeline:

```
recvfrom(:7000) → Data (Annex-B NAL with 00 00 00 01 start code)
→ H264DecoderShared.feed(nal)
→ if NAL=7: save SPS, try initSession()
→ if NAL=8: save PPS, try initSession()
→ if NAL=5/1: if no session → generate SPS/PPS → initSession() → decode()
→ VTDecompressionSessionDecodeFrame(session, sampleBuffer)
→ callback: CVImageBuffer → displayView.displayFrame(buf)
→ CALayer.contents = CGImage from CIImage(cvImageBuffer:)
```

### Известная ошибка в hardcoded SPS:
Байты SPS сгенерированы вручную, но могут не совпадать с тем что iPhone энкодер ожидает. `CMVideoFormatDescriptionCreateFromH264ParameterSets` может вернуть `-12909` (kVTCouldNotFindVideoDecoder) или `-12912`.

### Port архитектура:

```
iPhone: NWConnection → sends TO Mac:7000
iPhone: NWListener ← listens ON :7000
Mac:    BSD socket ← listens ON :7000 (blocking recvfrom on bg DispatchQueue)
Mac:    (НЕ отправляет видео — нет камеры)
```

## 9. РЕКОМЕНДАЦИЯ ДЛЯ СЛЕДУЮЩЕГО АГЕНТА

**Самый быстрый путь к работающему видео:**

1. Пересобрать iPhone с кодом SPS/PPS extraction (файл уже исправлен)
2. Проверить логи Mac — должны появиться NAL=7 и NAL=8
3. Декодер инициализируется → `🎬 FIRST FRAME DECODED!`
4. Добавить камеру на Mac для двусторонней связи

**Альтернатива (если не пересобирать iPhone):**
Правильно сгенерировать SPS/PPS байты. Можно получить точные байты, закодировав один тестовый кадр через VideoToolbox на Mac и выведя SPS/PPS в hex.
