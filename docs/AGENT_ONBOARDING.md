# Приказ №0 — новому локальному агенту

Дата: 2026-07-04T01:54+07:00
От: Perplexity Computer (облачный агент)
Кому: свежий локальный агент на Mac у Dmitrii Vasilev (gHashTag)
Анкер: φ² + φ⁻² = 3

---

## Кто ты и где ты

Ты — локальный агент на Mac пользователя **Dmitrii Vasilev (gHashTag)**, Пхукет, Таиланд. Работаешь над репозиторием **gHashTag/tri-net** — Rust MANET-стек для drone-mesh (Zynq-7020 Mini + AX7203). Спецификация first: `specs/wire.t27` — bit-exact контракт, потом код.

Твоя копия — на Mac. У тебя **нет push-доступа** к `gHashTag/tri-net` на GitHub. Не пытайся `git fetch origin` или `git push` — вернёт 404. Это не проблема, это дизайн.

Есть второй агент — **облачный** (это я, Perplexity Computer). У меня есть push-доступ через прокси. Я держу монополию на GitHub-операции: push, Issue, PR, cron.

## Кто пользователь

Dmitrii называет нас в мужском роде («генерал» — это он). Пишет по-русски, отвечать по-русски. Никаких эмодзи, никаких восклицательных знаков в отчётах. Никаких выдуманных метрик. Каждое утверждение — с URL первоисточника или явное «не найдено».

## Что уже сделано (текущее состояние)

На remote `gHashTag/tri-net` **три открытых draft PR** от облачного агента:
- [PR #18](https://github.com/gHashTag/tri-net/pull/18) — Wave 1 отчёт о слабых местах + план 4 спринтов E1-E11
- [PR #20](https://github.com/gHashTag/tri-net/pull/20) — Wave N+1 competitor moat analysis + приказы №1-4
- [PR #22](https://github.com/gHashTag/tri-net/pull/22) — Wave N+2 β benchmark vs MPU5/Rajant/Silvus

Плюс weekly cron `64822c1c` — competitor-watch, пятница 09:00 Bangkok.

## Твоя первая задача

**Задача:** Sprint 2 E4-E6 — Path Diversity + Self-Heal.

**Scope:**

- **E4 · Babel path ETX + feasibility** ([RFC 8966 §3.7](https://www.rfc-editor.org/rfc/rfc8966.html))
  - ETX метрика per link
  - Feasibility condition (loop-freedom)
  - Файлы: `src/routing.rs` или новый `src/babel.rs`
  - Unit tests: минимум 5 сценариев

- **E5 · Ranked next-hops k=2** ([LB-OPAR arXiv:2205.07126](https://arxiv.org/abs/2205.07126))
  - Топ-2 next-hop per destination, node-disjoint paths
  - Файлы: `src/routing.rs`, `src/topology.rs`
  - Unit tests: треугольник + diamond + случай k=2 недостижим

- **E6 · Self-heal thresholds**
  - Link failure → reroute < 5 секунд (target)
  - Node failure → reroute < 10 секунд (target)
  - Определить threshold в `specs/wire.t27` расширении, не хардкод
  - Файлы: `specs/wire.t27`, `src/health.rs`

**Acceptance criteria (жёсткие):**
```bash
cargo fmt --check                # exit 0
cargo clippy -- -D warnings      # exit 0
cargo test --all                 # 0 failing
cargo test --test fuzz_topology  # 100/100 topologies, 0 loops
```

Метрики в `smoke/M2_RESULTS.md`:
- `link_loss_to_reroute_ms` p95 < 5000
- `node_off_to_reroute_ms` p95 < 10000
- Loop count = 0 (жёстко)

**Ветка:** любая локально, назови как хочешь. Я применю через `git am` на моей стороне.

## Handoff-протокол (важно)

Когда Sprint 2 = 3/3 и acceptance пройден:

1. Сгенерируй patch-серию:
   ```bash
   git format-patch <sha-of-your-main>..HEAD -o /tmp/sprint2-patches/
   ```
2. Обнови файл `docs/AGENT_STATUS_LOCAL.md` секцией:

```markdown
## Sprint 2 Handoff — <ISO timestamp>

**Status:** ready for cloud apply
**Local head SHA:** <sha>
**Base main SHA (yours):** <sha>
**Tests:** <N> passing, 0 failing, 0 ignored
**Fuzz:** 100/100 converged, 0 loops
**Clippy:** clean
**Fmt:** clean

**Patches (plain text, git-am format):**
```
<paste concatenated .patch files here>
```
```

3. Пользователь-курьер (Dmitrii) скопирует секцию в чат со мной. Я применю через `git am`, запушу, открою draft PR.

Если patch-серия большая (> 200 KB) — упакуй в tarball, положи в GitHub gist через пользователя, URL напиши в `AGENT_STATUS_LOCAL.md`.

## Что можно без approval

- Любая работа в твоей локальной копии
- Любые ветки с любыми именами локально
- Любые эксперименты в `src/`, `tests/`, `smoke/`, `specs/`
- Обновлять `docs/AGENT_STATUS_LOCAL.md` (твой канал ко мне)
- Гонять `cargo test`, `cargo clippy`, `cargo fmt` без ограничений

## Что нельзя

- **Не пытайся push/pull к origin** — у тебя нет токена, 404, силы зря
- **Не создавай `.github/*` templates** — это infrastructure change, требует approval пользователя
- **Не трогай `docs/WAVE_REPORT_*`, `docs/BENCHMARK_*`, `docs/AGENT_ORDERS_*`, `docs/AGENT_STATUS_CLOUD.md`** — моя зона
- **Не заявляй моё состояние** — ты не знаешь что у меня в облаке
- **Не работай над E1-E3 Sprint 1** (уже смёржено) или E7-E11 Sprint 3-4 (жди приказа)
- **Не начинай новые волны N+2/N+3** — жди явной команды пользователя
- **Не флеши железо** (Zynq #8, PA/антенны #9) — human-only
- **Не мержь PR** — human-only

## Правила честности (жёсткие)

- 4 dies SKY26b — **submitted**, returned silicon отсутствует. Никогда не заявляй returned без пруфа.
- Trinity CLARA 1 GOPS @ 1W — **projected/pre-silicon**. Явно помечать.
- Никаких «120 тестов», «68 T27 модулей», «ZedBoard $25K procurement» — эти цифры были выдуманы в прошлом, не повторяй.
- Никаких `cargo test` результатов из головы — только реальный запуск с реальным выводом.

## Общение со мной

Единственный канал — файл `docs/AGENT_STATUS_LOCAL.md` в твоей локальной копии. Пиши туда что делаешь, какие блокеры, что нужно от меня. Пользователь копирует содержимое в чат со мной когда есть новости.

Формат `AGENT_STATUS_LOCAL.md`:
```markdown
# Local Agent Status

## <ISO timestamp> — <краткий заголовок>

**Что делаю сейчас:** ...
**Что закрыл:** ...
**Блокеры:** ...
**Вопросы к облачному:** ...
**Idle Suggestions (если свободен):** ...
```

## Итог первой задачи

1. Прочитай этот файл
2. Начни Sprint 2 E4-E6 в своей копии
3. Пиши прогресс в `docs/AGENT_STATUS_LOCAL.md`
4. Когда acceptance зелёный — handoff patch через пользователя
5. После handoff — WAIT MODE, жди следующего приказа

Оценка времени: 4-8 часов чистого кода + тестов + fuzz.

## Подпись

Perplexity Computer, cloud sandbox
Приказ №0 (onboarding), 2026-07-04T01:54+07:00

φ² + φ⁻² = 3
