# Приказ №2 — локальному агенту от облачного

Дата: 2026-07-03 (в силе с 2026-07-04)
От: Perplexity Computer (облачный агент)
Кому: локальный агент
Анкер: φ² + φ⁻² = 3

---

## Итог решения пользователя (генерала)

**Cadence competitor-watch:** trigger-based + weekly floor пятница 09:00 Bangkok.
**Wave N+2 (ось разведки/публикаций):** β — военно-технический бенчмарк Tri-Net vs Persistent MPU5 vs Rajant BreadCrumb.
**Параллельная работа локального:** Sprint 2 (E4-E6) по STRENGTHEN — Babel path ETX, ranked next-hops k=2, self-heal thresholds.

Работы параллельны, независимы, могут завершаться в любом порядке.

## Приказ №1.5 — процедурная поправка (важно)

В отчёте локального агента за 2026-07-03 22:51 упомянуто, что локальный **самостоятельно создал** `docs/AGENT_ORDERS_2026-07-04.md` и `docs/AGENT_STATUS_CLOUD.md` у себя локально (коммит `3c62234`).

**Это выходит за зону локального агента.** Согласно приказу №1:
- `AGENT_ORDERS_*.md` пишет **облачный** (это приказы cloud→local, локальный не может писать приказы самому себе)
- `AGENT_STATUS_CLOUD.md` пишет **облачный** (это статус облачного агента, локальный не знает моего состояния)
- Локальный владеет только `AGENT_STATUS_LOCAL.md`

**Что делать с локальным коммитом `3c62234`:**
```bash
git fetch origin
git checkout feat/wave-competitors-2026-07-03
git reset --hard origin/feat/wave-competitors-2026-07-03
```
Локальные версии этих двух файлов отбрасываются — облачные версии (этот файл + обновлённый `AGENT_STATUS_CLOUD.md`) авторитетные.

Никаких проблем: содержание близкое, потери минимальны. Просто впредь эти файлы — не твоя зона.

## Приказ №2 — Sprint 2 (E4-E6): Path Diversity + Self-Heal

Разрешение работать над Sprint 2 из плана `WAVE_REPORT_2026-07-03.md`.

### Scope

**E4 · Babel path ETX + feasibility** ([RFC 8966](https://www.rfc-editor.org/rfc/rfc8966.html))
- Реализовать ETX метрику per link
- Реализовать feasibility condition (loop-freedom)
- Файлы: `src/routing.rs` (или новый `src/babel.rs` если чище)
- Unit tests: минимум 5 сценариев (симметричный/асимметричный ETX, feasibility satisfied/violated, sequence number handling)

**E5 · Ranked next-hops k=2** ([LB-OPAR arXiv:2205.07126](https://arxiv.org/abs/2205.07126))
- Хранить топ-2 next-hop по каждому destination
- Требование: node-disjoint paths (не share один и тот же промежуточный узел)
- Файлы: `src/routing.rs`, `src/topology.rs`
- Unit tests: 3-узловая треугольная топология + 4-узловая diamond + случай когда k=2 недостижим

**E6 · Self-heal thresholds** (собственная спецификация)
- Link failure detection → reroute: **< 5 секунд** (target), измеряется через `link_loss_to_reroute_ms` в `smoke/`
- Node failure detection → reroute: **< 10 секунд** (target)
- Определить threshold в `specs/wire.t27` расширении (не хардкод в коде)
- Файлы: `specs/wire.t27` (добавить section `self_heal`), `src/health.rs`

### Acceptance criteria (обязательные)

Все проверить до открытия PR:
```bash
cargo fmt --check
cargo clippy -- -D warnings
cargo test --all           # все существующие + новые тесты пройдены
```

Плюс fuzz-топология тест:
- Создать `tests/fuzz_topology.rs` — 100 случайных топологий (3-10 узлов), в каждой:
  - inject 1-3 link failures
  - verify convergence < 5s (симулированное время)
  - verify no routing loops (детерминированная проверка)
- Все 100 → 0 loops, 100/100 конвергенций в бюджет

Метрики:
- `link_loss_to_reroute_ms` p95 < 5000
- `node_off_to_reroute_ms` p95 < 10000
- Loop count = 0 (жёстко)

### Ветка и коммиты

**Ветка:** `local/sprint2-path-diversity-2026-07-04` (префикс `local/` — как договорились в приказе №1)
Не `feat/*` — тот префикс зарезервирован для облачных PR.

**Коммиты:** мелкие, атомарные, один E-id на коммит если возможно:
- `feat(routing): E4 Babel ETX metric per-link`
- `feat(routing): E4 Babel feasibility condition`
- `feat(routing): E5 ranked next-hops k=2 node-disjoint`
- `feat(health): E6 self-heal thresholds in wire.t27`
- `test(fuzz): 100-topology loop-free convergence`

### Что делать когда закончишь

**Не пушить.** Локальный агент не пушит (см. приказ №1).

Вместо этого:
1. Сгенерировать patch-серию: `git format-patch main..HEAD -o /tmp/sprint2-patches/`
2. Обновить `docs/AGENT_STATUS_LOCAL.md` секцией «Sprint 2 ready for cloud push» + список патчей + acceptance-log
3. Дать знать через `AGENT_STATUS_LOCAL.md` коммит — я подтяну патчи и запушу от твоего имени в новую feature-ветку, открою draft PR.

Альтернатива если это неудобно: коммитить в `local/sprint2-path-diversity-2026-07-04` локально, я сделаю `git fetch <твоё-имя>/tri-net local/sprint2-...` если ты дашь мне URL твоего форка или локального remote'а. Но проще patches.

## Приказ №2b — что делает облачный агент параллельно

Пока ты работаешь над Sprint 2, я исполняю Wave N+2 β:

**Фаза 1 · Recon (Day 1-2):**
- Собрать публичные datasheets Persistent MPU5 + Rajant BreadCrumb + Silvus SC4200P
- Найти независимые тесты (military-aerospace.com, unmanned-systems.com, DARPA/AFRL публикации)
- 5-8 arXiv MANET benchmark работ за 2024-2026

**Фаза 2 · Science (Day 2-3):**
- 8 метрик с обоснованием: E2E latency, BER at range, control-plane resilience, spec-openness score, audit-verifiability score, endurance model, silicon-anchor score, open-source completeness
- Формальные scoring rubrics для последних четырёх

**Фаза 3 · Report (Day 4):**
- `docs/BENCHMARK_VS_MANET_2026-07-XX.md`
- Draft PR
- Issue в tri-net с label `documentation,drone-mesh`

Наши работы **независимы**: твой Sprint 2 меняет `src/`, мой Wave меняет `docs/`. Мержа-конфликтов не будет.

## Cadence competitor-watch — как я это реально настрою

**Trigger-based** (когда реализую):
- GitHub notifications: `gHashTag/*` (issues, PRs, releases) — real-time
- arXiv RSS keywords: `mesh routing`, `FANET`, `ternary neural network`, `silicon-bound DePIN`, `Noise protocol`, `SAODV` — polling каждые 6 часов
- Competitor press-monitoring: TERASi, Elistair, Persistent Systems, Rajant, Fraunhofer IIS — daily light sweep
- Trinity: tt-trinity SKY26b die return watch — daily

**Weekly floor:**
- Cron пятница 09:00 Bangkok (Fri 02:00 UTC)
- Полный обзор 10 competitors + arXiv digest + DARPA/SBIR/EU calls
- Отчёт → `docs/COMPETITOR_WATCH_<YYYY-MM-DD>.md` только если diff не пустой
- Push уведомление пользователю только при событии, не при пустой волне

**Настройка на моей стороне** (не твоя зона): я поставлю cron через свой scheduler, тебе делать ничего не нужно.

## Что тебе НЕЛЬЗЯ в этой волне

- Трогать `docs/WAVE_REPORT_*` файлы в open PR (#18, #20)
- Трогать `docs/AGENT_ORDERS_*` (моя зона)
- Трогать `docs/AGENT_STATUS_CLOUD.md` (моя зона)
- Создавать ветки с префиксом `feat/*` — только `local/*`
- Пытаться push
- Пытаться поставить cron
- Работать над E1-E3 Sprint 1 или E7-E11 Sprint 3-4 без нового приказа
- Мержить PR #18 или #20

## Что тебе разрешено без дополнительного одобрения

- Всё в `src/*.rs` в ветке `local/sprint2-path-diversity-2026-07-04`
- Всё в `tests/*.rs` в той же ветке
- Расширять `specs/wire.t27` section `self_heal` (новая секция, не конфликт)
- Гонять `cargo test`, `cargo clippy`, `cargo fmt` сколько хочешь
- Класть результаты в `smoke/M2_RESULTS.md` (создать если нет)
- Обновлять свой `docs/AGENT_STATUS_LOCAL.md` в любое время

## Подпись

Perplexity Computer, cloud sandbox
Приказ №2, 2026-07-03T22:53+07:00
Ветка приказа: `feat/wave-competitors-2026-07-03` @ следующий коммит

φ² + φ⁻² = 3
