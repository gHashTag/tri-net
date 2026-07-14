# E1.1 · iPhone ↔ P203 Mini topology decision

phi^2 + phi^-2 = 3

**Status:** DRAFT · pre-hardware · `-sim` для performance, `-cite` для API поведения
**Owner:** Lane A (PWA-first) · first task, unblocked без merge других PR
**Related:** wave report `docs/WAVE_IPHONE_ADMIN_2026-07-14.md`, PR #79 (M2 TUN), PR #63/#65 (Noise)

## 1 · Задача

Выбрать **физический канал** между iPhone (пользовательский клиент — admin dashboard PWA + PTT) и P203 Mini (mesh-узел, Zynq-7020, ARM Cortex-A9 + Artix-7 PL). Канал должен:

1. Работать без jailbreak, без MFi certification, без App Store distribution (Lane A ограничения).
2. Пропустить IP-трафик достаточной пропускной способности для Opus PTT (24 kbps) + admin WebSocket (≤ 10 kbps steady).
3. Поддерживать mDNS/Bonjour discovery, чтобы Safari PWA нашла узел через `_trinet-admin._tcp.local`.
4. Быть измеримым в лабораторных условиях (не требовать OTA emissions license).

## 2 · Три кандидата

### Вариант A · USB Personal Hotspot (iPhone → P203)

**Направление:** iPhone раздаёт интернет/локальную сеть в P203. iPhone — DHCP server (172.20.10.1/28), P203 — client.

**Как работает на Linux:**
Стек `usbmuxd` + `libimobiledevice` + kernel `ipheth` driver представляет iPhone как `eth1` (class 0x0a). ArchWiki [iPhone tethering](https://wiki.archlinux.org/title/IPhone_tethering) документирует полный flow — `usbmuxd -f` + trust prompt на iPhone + DHCP client на Linux side.

**Плюсы:**
- Работает на всех iPhone начиная с iOS 3 (Personal Hotspot появился давно, USB path стабилен).
- Все Yocto/PetaLinux сборки для Zynq имеют kernel option `CONFIG_USB_IPHETH` — включаемо.
- Пользователь просто нажимает «Personal Hotspot» в Settings.
- Zero apple-side coding — iPhone делает host duty.

**Минусы:**
- iPhone получает **приоритет DHCP** — узел P203 виден как «internet client», а не наоборот. Admin PWA на iPhone должна обращаться к узлу по DHCP-assigned адресу узла (172.20.10.2/3/…), который iPhone контролирует.
- Требует USB-C-to-Lightning или USB-C-to-USB-C кабель (iPhone 15+ имеет USB-C).
- Personal Hotspot требует активной SIM карты в некоторых операторов (не везде — MVNO часто блокируют hotspot). Обход: включить в Airplane mode + Wi-Fi off, тогда tether работает без cell.
- **iOS 14+ NSLocalNetworkUsageDescription:** iPhone Safari разрешает mDNS-browse только с explicit purpose-string prompt. См. [Apple Local Network Privacy FAQ](https://developer.apple.com/forums/thread/663858).

**Compatibility:** iPhone 12 и новее ✅ (все имеют Personal Hotspot). Lightning cable → USB-A на P203 USB host port.

**Estimated goodput:** 480 Mbps USB 2.0 theoretical, ~50-100 Mbps практически `-cite`. Хватит на всё.

**Verdict: PRIMARY choice для Lane A v0.1.**

### Вариант B · Reverse tethering (P203 → iPhone via `USBMUXD_DEFAULT_DEVICE_MODE=3`)

**Направление:** P203 раздаёт сеть в iPhone. Устанавливается через нестандартный usbmuxd flag.

**Как работает:**
[libimobiledevice#1348](https://github.com/libimobiledevice/libimobiledevice/issues/1348) описывает workaround: rebuild `usbmuxd` с patch, экспортить `USBMUXD_DEFAULT_DEVICE_MODE=3`, iPhone видит host как DHCP server через USB. Не документировано Apple, работает эмпирически.

**Плюсы:**
- P203 контролирует IP-план: iPhone получает адрес из mesh-плана (например 10.42.0.5/24), напрямую маршрутизируется в TUN interface `trios_meshd`.
- Не требует iPhone Personal Hotspot (не потребляет cellular data).

**Минусы:**
- Требует **custom usbmuxd build** на Yocto — не в mainline. Support-cost на каждом OS-upgrade.
- Не документировано Apple → может сломаться с любой iOS версией.
- **iOS не запускает DHCP client автоматически** для USB Ethernet без Personal Hotspot mode — работает только если iOS считает link «Ethernet-like» через специфичный USB class descriptor.
- Требует изменения PetaLinux root filesystem — не «включи и пользуйся».

**Verdict: FALLBACK на будущее.** Не для v0.1. Track для Lane B (native app) где всё равно custom stack нужен.

### Вариант C · Wi-Fi hotspot от P203, iPhone в STA-mode

**Направление:** P203 — AP, iPhone — station.

**Как работает:**
Требует Wi-Fi модуль на P203 (AD9361 может OFDM, но это не 802.11 — надо либо cheap TL-WN722N-like USB dongle, либо интегрировать 802.11 stack на AD9361 через [openwifi arXiv:2003.09525](https://arxiv.org/abs/2003.09525)).

**Плюсы:**
- Полная беспроводная свобода. iPhone не привязан к плате физически.
- iOS полноценно поддерживает join to Wi-Fi network, no permission issues (кроме NSLocalNetworkUsageDescription для Bonjour).
- Естественный fit для «walkie-talkie» use case — user ходит с iPhone в кармане.

**Минусы:**
- **Требует hardware, которого сейчас у нас нет** в mainline P203 Mini конфиге. openwifi на AD9361 — R&D проект (тот самый arXiv paper), не production.
- USB Wi-Fi dongle: занимает USB port, требует kernel drivers, hostapd config, DHCP server (dnsmasq) — целый стек.
- Wi-Fi mesh vs Tri-Net mesh — двойной network layer, где-то трафик надо мостить.

**Verdict: FUTURE (Sprint 4+).** Не для первой демонстрации. Приоритет: сначала доказать pipeline на USB, потом делать беспроводным.

## 3 · Decision matrix

| Критерий | A (Personal Hotspot) | B (Reverse tether) | C (Wi-Fi AP) |
|---|---|---|---|
| iPhone compatibility | все iOS ✅ | все iOS ✅ | все iOS ✅ |
| P203 side kernel | mainline `ipheth` ✅ | custom `usbmuxd` ❌ | USB dongle + hostapd ⚠️ |
| Hardware cost | $0 (кабель) | $0 (кабель) | ≥ $15 (USB dongle) |
| Setup complexity | user tap в Settings | rebuild + env var | full 802.11 config |
| Long-term stability | Apple-supported path | undocumented | если openwifi — R&D risk |
| PTT bandwidth | 50-100 Mbps `-cite` | same | 20-50 Mbps на 2.4 GHz `-sim` |
| Mobility | привязан кабелем | привязан кабелем | free-roam ✅ |
| **Приоритет для v0.1** | **PRIMARY** | fallback | future |

## 4 · Выбранный path для v0.1

**Variant A — USB Personal Hotspot.**

Rationale:
1. Работает **сегодня** без custom kernel builds.
2. Нулевой hardware BOM add.
3. Позволяет измерить всё остальное (PWA discovery, WebSocket, Opus) в честном IP-окружении, не engineering-around-USB.
4. Не блокирует Variant C — когда Wi-Fi модуль появится, тот же PWA/WebSocket/mDNS stack переиспользуется 1:1.

## 5 · Reference network topology

```
┌─────────────┐   Lightning/USB-C   ┌──────────────┐   Tri-Net mesh   ┌──────────────┐
│   iPhone    │◄────────────────────┤  P203 Mini   │◄─── UDP+radio ──►│  P203 Mini   │
│  (Safari    │  iOS Personal       │  (Zynq-7020, │                  │  (peer node) │
│   PWA)      │  Hotspot; iPhone    │  Yocto Linux)│                  │              │
│  172.20.10.x│  DHCP server        │  172.20.10.2 │                  │              │
└─────────────┘                     └──────┬───────┘                  └──────────────┘
                                           │
                                           │ mDNS: _trinet-admin._tcp.local
                                           │       port 8443 (admin PWA + WS)
                                           │       port 5000 (mesh UDP, existing)
                                           │
                                           ▼
                                   ┌──────────────┐
                                   │ admin_httpd  │  ← новый бинарь (E2.1/E2.2)
                                   │ (this repo)  │
                                   └──────────────┘
```

## 6 · Смок-план (без реального iPhone, sandbox-level)

Верификация IP-layer через `netcat` / `curl` симулирует поведение iPhone Safari — все реальные HTTP/WS/mDNS вызовы будут теми же.

```bash
# On dev host (proxy for iPhone side)
curl -k https://<p203-ip>:8443/api/status
# expected: JSON with node_id, uptime, neighbor list, ETX table

# mDNS discovery (proxy for iOS Bonjour browse)
avahi-browse -r _trinet-admin._tcp
# expected: single record, TXT includes node_id + version

# WebSocket ping (proxy for PWA long-poll)
websocat wss://<p203-ip>:8443/ws
# send: {"type":"subscribe","topic":"neighbors"}
# expect: heartbeat every 1s
```

Реальный iPhone smoke — отдельная задача с hardware access (M2 milestone).

## 7 · Что этот документ не решает

- Не решает **authentication** — mTLS + QR pairing идёт в E2.2.
- Не решает **background audio** на iOS — foreground-only для v0.1 (см. wave report §7).
- Не измеряет реальную latency — все числа `-sim` до hardware smoke.
- Не покрывает случай «iPhone без Personal Hotspot capability» (enterprise-managed devices, некоторые MVNO) — те пользователи ждут Variant C.

## 8 · Что unblock'ается после merge

- E2.1 (PWA skeleton + mDNS) — уже готова к работе после этого документа.
- E2.2 (admin API + mTLS) — стартует параллельно с E2.1.
- E3.x (PTT pipeline) — не зависит от topology, стартует независимо.

phi^2 + phi^-2 = 3
