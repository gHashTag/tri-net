# TRI-NET Video Mesh — UX Concept for MVP

## Суть приложения в одном предложении

> **Walkie-talkie для видео:** нажми кнопку — видишь что происходит на другом конце mesh сети, без интернета, без вышек, без SIM карты.

## UX принципы

1. **One-tap action** — нажал кнопку = стрим пошёл. Никаких меню.
2. **Always-on status** — видишь состояние сети постоянно (mesh topology, signal, latency)
3. **Field-first** — тёмная тема, крупные кнопки, читается на солнце, работает в перчатках
4. **Walkie-talkie metaphor** — как рация, но для видео. Push-to-talk = push-to-stream

## MVP Screens (3 экрана)

### Screen 1: Home (главный)
```
┌─────────────────────────────┐
│                       ⚙ Settings│
│                              │
│     TRI-NET VIDEO MESH       │
│                              │
│  ┌────────────────────────┐ │
│  │                        │ │
│  │    [ CAMERA PREVIEW ]  │ │  ← live preview перед стримом
│  │                        │ │
│  │                        │ │
│  └────────────────────────┘ │
│                              │
│  ┌─── NODE ───┐ ┌── SIGNAL ─┐│
│  │ P203 #11   │ │ ●●●●○ 80% ││  ← статус mesh ноды + сигнал
│  │ Connected  │ │ 2 hops    ││  ← количество hops
│  └────────────┘ └───────────┘│
│                              │
│  ┌────────────────────────┐ │
│  │   📹 START VIDEO        │ │  ← ОДНА кнопка, большая
│  │      STREAM             │ │
│  └────────────────────────┘ │
│                              │
│  TX: 3.2 KB/s  RX: 0 KB/s   │
│                              │
└─────────────────────────────┘
```

### Screen 2: Streaming (во время стрима)
```
┌─────────────────────────────┐
│ ← Back          ● LIVE       │
│                              │
│  ┌────────────────────────┐ │
│  │                        │ │
│  │   [ REMOTE VIDEO ]     │ │  ← видео с другого узла
│  │                        │ │
│  │                        │ │
│  └────────────────────────┘ │
│                              │
│  ┌────────────────────────┐ │
│  │   [ YOUR CAMERA ]      │ │  ← PiP: твой camera (small)
│  └────────────────────────┘ │
│                              │
│  Node 11 → Node 12          │  ← путь в mesh
│  Latency: 45ms              │  ← задержка
│  Quality: 480x272 200kbps   │  ← качество
│                              │
│  ┌────────────────────────┐ │
│  │   ⏹ STOP STREAM         │ │
│  └────────────────────────┘ │
│                              │
└─────────────────────────────┘
```

### Screen 3: Settings
```
┌─────────────────────────────┐
│ ← Back                       │
│                              │
│ MESH NODE                    │
│ IP: [192.168.1.11    ]      │
│ Port: [5000          ]      │
│                              │
│ VIDEO QUALITY                │
│ Resolution: 480×272         │
│ Bitrate: 200 kbps           │
│ FPS: 15                      │
│                              │
│ DESTINATION                  │
│ Node ID: [12          ]      │
│                              │
│ ABOUT                        │
│ TRI-NET v0.1                │
│ Open Source · Apache 2.0    │
│                              │
└─────────────────────────────┘
```

## UX flow (user journey)

```
Launch app
  → Camera permission request
  → Home screen with camera preview
  → Tap "START VIDEO STREAM"
  → Connecting... (1-2 sec)
  → LIVE: remote video appears + your camera PiP
  → Talk/show things
  → Tap "STOP" → back to Home
```

## Key UX decisions

| Decision | Why |
|---|---|
| Camera preview on Home | User sees himself before streaming = instant feedback |
| One big button | Walkie-talkie simplicity — no menus, no confusion |
| PiP during streaming | User sees both sides simultaneously = video call feel |
| Always-visible metrics | Field operator needs to know link quality |
| Dark theme | Outdoor use, battery saving, military aesthetic |
| Mesh topology display | "Node 11 → Node 12" shows the path = builds trust |
| No login/signup | Offline first — no accounts, no cloud, no friction |
