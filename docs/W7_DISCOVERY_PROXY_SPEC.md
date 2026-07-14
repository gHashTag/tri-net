# W7 — RFC 8766 Discovery Proxy prototype spec

phi^2 + phi^-2 = 3

Дата: 2026-07-14
Волна: W7 part-3, workstream W7 (не путать с W7 wave).
Статус: **spec-first draft**. Runtime skeleton — `src/bin/mdns_proxy.rs`. Полный DNS Push (RFC 8765) и cross-subnet caching — вне scope этого draft'а.

## Проблема

mDNS работает только внутри одного link-local L2-сегмента (multicast 224.0.0.251 не роутится). Три P203 Mini на разных подсетях (например node-11 на 10.0.0.11/24, node-12 на 10.0.1.12/24, node-13 на 10.0.2.13/24) не увидят друг друга через Bonjour.

При этом mesh-транспорт `trios_meshd` уже несёт IP-пакеты между узлами через UDP-overlay. Значит устройство discovery можно выполнить внутри overlay — с одной стороны стоит **Discovery Proxy**, который принимает обычные mDNS запросы на link-local интерфейсе и транслирует их поверх mesh к целевому node'у.

## Цель прототипа

Минимальный runtime, который:

1. Слушает mDNS query на link-local UDP 5353 (уже делает `mdns_responder`).
2. Если query относится к службе, известной локально — отвечает сам (обычный mdns_responder путь).
3. Если query относится к службе на удалённом node'е — **проксирует** его к тому node'у через overlay-transport (в этом draft'е — простой TCP-канал, в будущем — trios_meshd envelope), и возвращает ответ обратно клиенту.

Прототип **НЕ** обеспечивает:

- Полный DNS Push (RFC 8765) с subscribe/notify.
- Cross-subnet caching с корректным TTL-management.
- Аутентификацию удалённого node'а (это отдельная задача — использует W3 audio_crypto envelope как основу).

## Прайор-арт (cited)

- [RFC 8766 — Discovery Proxy for Multicast DNS-Based Service Discovery](https://datatracker.ietf.org/doc/html/rfc8766). Полная спека.
- [RFC 8765 — DNS Push Notifications](https://datatracker.ietf.org/doc/html/rfc8765). Позволяет клиенту оставаться подписанным на изменения без polling.
- [Apple Bonjour Gateway](https://developer.apple.com/documentation/bonjour). Проприетарная реализация в macOS Server; закрыт в 2019, но задал baseline.
- [Mist Bonjour Gateway](https://www.mist.com/documentation/bonjour-gateway-2/). Коммерческий mesh-mDNS proxy; ссылка для сравнения UX.
- [Avahi](https://wiki.archlinux.org/title/Avahi). Open-source Linux mDNS/DNS-SD stack; не имеет встроенного Discovery Proxy, только `avahi-reflector` для broadcast bridging (не то же самое).

## Non-claims

- Не заявляем что это полная реализация RFC 8766. Секция 6 (Rate Limiting), 7 (Administratively Prohibited Names), 8 (Considerations for Deployment) в этом draft'е НЕ рассмотрены.
- Не заявляем DoS-стойкость. Прототип без rate-limiting; злонамеренный клиент может делать 10k queries/s.
- Не заявляем что overlay-transport криптостоек. Для этой волны overlay = plain TCP; заменяется на audio_crypto envelope (W3) при интеграции.

## Wire layout — overlay proxy query

Кадр от локального прокси к удалённому node'у через overlay:

```
byte 0        : proxy_version (u8) = 1
byte 1..2     : txid (u16 BE) — совпадает с txid оригинального mDNS query
byte 3..4     : qtype (u16 BE)
byte 5        : qname_len (u8, максимум 255)
byte 6..      : qname (qname_len bytes, ASCII dotted form; without trailing dot)
```

Ответ:

```
byte 0        : proxy_version (u8) = 1
byte 1..2     : txid (u16 BE)
byte 3        : status (u8): 0=ok, 1=not-found, 2=error
byte 4..5     : payload_len (u16 BE)
byte 6..      : payload (mDNS answer packet, ready to be sent back to client verbatim)
```

## Предикаты (для spec-first валидации)

```
fn proxy_version_valid(v: u8) -> bool { v == 1 }
fn qname_valid(name: &str) -> bool { !name.is_empty() && name.len() <= 255 }
fn status_valid(s: u8) -> bool { s <= 2 }
fn envelope_min_len_query() -> usize { 6 }   // header only, qname_len=0 forbidden
fn envelope_min_len_reply() -> usize { 6 }   // header only, payload_len=0 allowed
```

## Runtime skeleton — что делает `src/bin/mdns_proxy.rs`

```
1. bind UDP 5353 на link-local (как mdns_responder)
2. bind TCP на overlay-port (default 5354) — принимает overlay proxy queries
3. на каждый входящий mDNS-запрос из UDP 5353:
   a. если parse_all_questions даёт вопрос про локальную службу — build_reply, отправить обратно
   b. если про foreign — если знаем какой node её обслуживает (статический routing table на сейчас), открыть TCP-соединение к его overlay-port, послать overlay query
   c. получить overlay reply, отправить payload обратно клиенту как mDNS answer
4. на каждый входящий overlay proxy query:
   a. проверить envelope, распаковать qname/qtype
   b. вызвать handle_query как если бы это был обычный mDNS
   c. упаковать ответ в overlay reply envelope, отправить обратно
```

**Static routing table** (для прототипа):
```
_trinet-admin._tcp.local → node-11 → 10.0.0.11:5354
```

В настоящем deployment таблица заполняется из consensus'а mesh (кто какую службу advertises).

## Тесты (обязательный minimum для acceptance)

1. `proxy_envelope_wrap_unwrap_roundtrip` — build overlay query, распарсить, поля совпадают.
2. `proxy_rejects_bad_version` — версия 2 отклоняется.
3. `proxy_rejects_too_long_qname` — 256-байтный qname отклоняется.
4. `proxy_end_to_end_local_service` — mDNS query на локальную службу отвечен без обращения к overlay.
5. `proxy_end_to_end_remote_service` — mDNS query на foreign службу вызывает overlay TCP-соединение к моку удалённого node'а, ответ возвращается клиенту.

Тесты 1-3 — unit; 4-5 — smoke (два процесса mdns_proxy на разных loopback портах).

## Что закрывается этой волной

- Spec-документ (этот файл) — фиксирует wire layout и minimum acceptance criteria.
- Runtime skeleton `src/bin/mdns_proxy.rs` — envelope wrap/unwrap функции + предикаты + unit-тесты 1-3.

## Что откладывается на следующую волну

- Полный end-to-end runtime с двумя процессами (тесты 4-5).
- Интеграция с trios_meshd overlay вместо plain TCP.
- Замена overlay-plain-TCP на audio_crypto envelope (W3) для confidentiality + integrity.
- RFC 8765 DNS Push для длинных подписок клиента без polling.
- Cross-subnet TTL-management (RFC 8766 §5.5.1).

## Anti-anchor discipline

- Каждое предложение о поведении runtime в этой волне — «skeleton» (envelope + predicates + unit tests), не «working end-to-end proxy». End-to-end остаётся conjecture до появления тестов 4-5.
- Все ссылки на RFC 8766 разделы — с URL и без переклэйма.

phi^2 + phi^-2 = 3
