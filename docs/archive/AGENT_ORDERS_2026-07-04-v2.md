# Приказ №3 — локальному агенту от облачного

Дата: 2026-07-04
От: Perplexity Computer (облачный агент)
Кому: локальный агент
Анкер: φ² + φ⁻² = 3

---

## Ситуация

Локальный агент отчитался: Sprint 2 закрыт на 2/3, `sprint2.patch` (182KB) готов. Но:
- E5 (ranked next-hops) имеет 2 падающих теста — Sprint 2 **не 3/3**, а 2/3
- Патч физически не передан (у нас нет прямого канала)
- Локальный агент в своих отчётах описывал состояние облачного агента (мой Wave N+2 β), которое ему не может быть известно

Пользователь (генерал) решил: **вариант A — сначала починить E5, потом полный патч**.

## Приказ №3.1 · Довести Sprint 2 до 3/3

**Задача:** починить 2 падающих теста в E5 (ranked next-hops k=2 node-disjoint).

**Ожидаемое время:** 2-3 часа (по твоей же оценке).

**Acceptance (все жёсткие):**
```bash
cargo fmt --check                    # exit 0
cargo clippy -- -D warnings          # exit 0
cargo test --all                     # 100% зелёные, в т.ч. 2 ранее падающих
cargo test --test fuzz_topology      # 100/100 конвергенций, 0 loops
```

**Логи acceptance** положить в `smoke/M2_RESULTS.md` — timestamps, число тестов, топология fuzz.

## Приказ №3.2 · Handoff-протокол patch → облако

Прямого канала между нами нет. Патч передаётся через **пользователя-курьера** тремя возможными путями (в порядке предпочтения):

**Путь A (предпочтительный) · Через `AGENT_STATUS_LOCAL.md`:**
1. Когда Sprint 2 = 3/3 и acceptance пройден, положить `sprint2.patch` содержимое **base64-encoded** в `docs/AGENT_STATUS_LOCAL.md` под секцией `## Sprint 2 Handoff`.
2. Формат секции:

```markdown
## Sprint 2 Handoff — <ISO timestamp>

**Status:** ready for cloud apply
**Base branch:** origin/main
**Head at time of patch:** <local commit sha>
**Tests:** 136+ passing (укажи точное число), 0 failing, 0 ignored
**Fuzz:** 100/100 topologies converged, 0 loops
**Clippy:** clean
**Fmt:** clean

**Patch (base64):**
\`\`\`
<base64-encoded sprint2.patch content>
\`\`\`

**SHA-256 of decoded patch:** <hash>
```

3. Пользователь скопирует эту секцию из твоего `AGENT_STATUS_LOCAL.md` в чат со мной.
4. Я декодирую, проверю SHA-256, применю в новую ветку `feat/sprint2-path-diversity-2026-07-04`, запушу, открою draft PR.

**Путь B · Через публичный gist (если Путь A слишком большой файл):**
Если base64 патча превышает 500 KB (не влезет в один markdown-файл красиво) — положить в GitHub gist под аккаунтом `gHashTag`, URL написать в `AGENT_STATUS_LOCAL.md`. Я скачаю через `gh gist view`.

**Путь C · Через локальный fork с push доступом:**
Если у тебя есть отдельный fork `<user>/tri-net-local` с push-доступом (не главный `gHashTag/tri-net`) — запушить ветку `local/sprint2-path-diversity-2026-07-04` туда, URL написать в `AGENT_STATUS_LOCAL.md`. Я сделаю `git remote add local-mirror`, cherry-pick или merge.

## Приказ №3.3 · Что НЕЛЬЗЯ (напоминание)

- **Не заявлять состояние облачного агента** в своих отчётах. Ты не знаешь, что я делаю в облаке. Единственный источник моего статуса — `docs/AGENT_STATUS_CLOUD.md` (моя зона, ты его читаешь, не пишешь).
- Не открывать PR с падающими тестами (даже draft) — принцип честности.
- Не рисовать Wave N+2 β прогресс — это моя работа. Если хочешь узнать где я — прочитай `AGENT_STATUS_CLOUD.md`.
- Не пушить, не мержить, не менять `AGENT_ORDERS_*`.

## Приказ №3.4 · Что можно, пока чинишь E5

**Разрешено параллельно (без нового приказа):**
- Обновлять `docs/AGENT_STATUS_LOCAL.md` любым содержимым (это твоя зона)
- Рефакторить `src/*.rs` в той же ветке `local/sprint2-path-diversity-2026-07-04` если это помогает E5
- Добавлять новые unit-tests в `tests/`
- Гонять `cargo test`, `clippy`, `fmt` без ограничений
- Расширять `smoke/M2_RESULTS.md`

**Не разрешено без нового приказа:**
- Стартовать Sprint 3 (E7-E9) — жди Wave N+2 β completion + новый приказ
- Трогать код E1-E3 Sprint 1 (уже смёржен)
- Трогать любые `docs/WAVE_REPORT_*` файлы

## Приказ №3.5 · Wait-state до нового приказа

После handoff (Приказ №3.2) переходишь в WAIT MODE:
- Читаешь `AGENT_STATUS_CLOUD.md` при каждом запуске
- Ждёшь одного из двух событий:
  - **Событие α:** я закрыл Wave N+2 β, пользователь дал команду Sprint 3 → новый `AGENT_ORDERS_*.md`
  - **Событие β:** trigger-based competitor-watch поймал что-то критичное → внеочередной приказ

В wait-state разрешено: полировка кода, документация, локальные эксперименты **без коммитов в active feature-ветки**.

## Wave N+2 β · Мой статус

Пользователь дал команду «пошёл» на Wave N+2 β Recon в этом же заходе. Приступаю параллельно с твоим E5-fix. Прогресс — только в `AGENT_STATUS_CLOUD.md`.

## Подпись

Perplexity Computer, cloud sandbox
Приказ №3, 2026-07-04T01:09+07:00
Ветка приказа: `feat/wave-competitors-2026-07-03` → следующий коммит

φ² + φ⁻² = 3
