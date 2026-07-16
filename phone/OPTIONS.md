# Cross-platform варианты для TRI-NET phone app

## Сравнение

| Framework | iOS | Android | Camera | H.264 | UDP | Скорость разработки |
|---|---|---|---|---|---|---|
| **Skip (Swift→Kotlin)** | ✅ native | ✅ Kotlin | ✅ AVFoundation→CameraX | ✅ | ✅ | Средняя (Swift на обе) |
| **Flutter (Dart)** | ✅ | ✅ | ✅ plugin | ✅ plugin | ✅ | Быстрая |
| **React Native** | ✅ | ✅ | ✅ | ✅ | ✅ | Быстрая |
| **SwiftUI + Skip** | ✅ | ✅ via Skip | ✅ | ✅ | ✅ | Средняя |
| **Native Swift iOS only** | ✅ | ❌ | ✅ AVFoundation | ✅ VideoToolbox | ✅ | Быстрая но iOS only |
| **Kotlin Multiplatform** | ✅ | ✅ | ⚠️ platform-specific | ⚠️ | ✅ | Средняя |

## Рекомендация для TRI-NET

### Вариант 1: Swift + SwiftUI (iOS first, Android через Skip)
- Пишешь на Swift — ты уже знаешь (AVFoundation capture tool работал!)
- iOS = primary target (телефон генерала)
- Android = через Skip когда понадобится
- H.264: VideoToolbox (iOS hardware encoder)
- Camera: AVFoundation (уже доказано работает)
- UDP: Network.framework (native, ноль зависимостей)

### Вариант 2: Flutter (оба сразу)
- Один кодbase для iOS + Android
- Camera plugin работает на обеих
- Но: Dart, не Swift. Нужно учить.
- H.264: flutter_video_encoder или platform channel

### Вариант 3: Swift iOS + Kotlin Android (native обе)
- Лучшее качество на каждой платформе
- Но: два кодbase. Долго.

## Мой совет: Вариант 1 (Swift + SwiftUI)
Причины:
1. Ты знаешь Swift (AVFoundation tool работал)
2. iOS = твой телефон (быстрый тест)
3. UDP + VideoToolbox = ноль внешних зависимостей
4. Skip может добавить Android позже
5. SwiftUI = минимальный код для UI

phi^2 + phi^-2 = 3
