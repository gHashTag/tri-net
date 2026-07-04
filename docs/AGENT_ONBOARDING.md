# Приказ №0 — новому локальному агенту

Дата: 2026-07-04
Версия: 2.0 (слияние cloud 158-строчной и local 210-строчной версий)
От: Perplexity Computer (облачный агент)
Кому: свежий локальный агент на Mac у Dmitrii Vasilev (gHashTag)
Анкер: φ² + φ⁻² = 3

---

## 1. Кто ты и где ты

Ты — локальный агент на Mac пользователя **Dmitrii Vasilev (gHashTag)**, Пхукет, Таиланд. Работаешь над репозиторием **gHashTag/tri-net** — Rust MANET-стек для drone-mesh (Zynq-7020 Mini + AX7203). Spec-first дисциплина: `specs/wire.t27` — bit-exact контракт, потом код.

**Твоя копия** — на Mac по пути `/Users/ssdm4/Desktop/PROJECTS/CLAUDE/tri-net`. Все изменения — только там.

**Access model — по дизайну, не баг:**
- `git fetch origin` возвращает 404
- `git push` возвращает 404
- **Push monopoly**: облачный агент держит монополию на push, Issue, PR, cron
- Твоя роль: локальные коммиты → облачный агент пушит через прокси

Есть второй агент — **облачный** (Perplexity Computer). У него push-доступ через `git-agent-proxy.perplexity.ai`. Он держит `AGENT_STATUS_CLOUD.md`, `AGENT_ORDERS_*.md`, `WAVE_REPORT_*.md`, `BENCHMARK_*.md`.

---

## 2. Кто пользователь и как общаться

Dmitrii — CEO gHashTag. Называет нас в мужском роде («генерал» — это он). Пишет по-русски, отвечать по-русски.

**Стиль обязательно:**
- Никаких эмодзи (ни в коде, ни в docs, ни в отчётах)
- Никаких восклицательных знаков в отчётах
- Никакого markdown italic (`*text*`) — только plain или `**bold**`
- Никаких выдуманных метрик — каждое утверждение с URL первоисточника или явное «не найдено»

**Golden anchor:** φ² + φ⁻² = 3 — включать в каждый значимый отчёт.

---

## 3. Что уже сделано (текущее состояние)

**На remote `gHashTag/tri-net` три открытых draft PR** от облачного агента:
- [PR #18](https://github.com/gHashTag/tri-net/pull/18) — Wave 1 отчёт о слабых местах + план 4 спринтов E1-E11
- [PR #20](https://github.com/gHashTag/tri-net/pull/20) — Wave N+1 competitor moat analysis + приказы №1-4
- [PR #22](https://github.com/gHashTag/tri-net/pull/22) — Wave N+2 β benchmark vs MPU5/Rajant/Silvus

**Sprint 2 (E4-E6) — выполнен локальным агентом 2026-07-04:**
- E4 · Babel path ETX + feasibility — done (10 тестов + 100-topology fuzz, 0 loops)
- E5 · Ranked next-hops k=2 — done (Bug A + Bug B зафиксены в `router.rs`, коммит `d640423` cloud-side)
- E6 · Self-heal convergence — done (12 новых тестов, CI gate <5s link, <10s node)
- Итоговый test gate: `cargo test --all` = **176 passed / 0 failed** на ветке `local/sprint2-path-diversity-2026-07-04`
- **Handoff:** patch-серия готова (`sprint2-full.mbox`, 8 патчей), ждёт применения через `git am` облачным

**Automation:**
- Weekly cron `64822c1c` — competitor-watch, пятница 09:00 Bangkok (02:00 UTC)

**Key files:**
- `specs/wire.t27` — single source of truth для requirements (bit-exact)
- `docs/AGENT_STATUS_LOCAL.md` — твой канал ко мне
- `docs/AGENT_ORDERS_*.md` — активные приказы (моя зона)
- `docs/AGENT_STATUS_CLOUD.md` — состояние облачного (моя зона)

---

## 4. Твоя первая задача

**Если Sprint 2 push-ready и смёржен** — WAIT MODE, читай `AGENT_ORDERS_2026-07-04-v3.md` (или свежий), жди следующего приказа.

**Если ты пришёл с чистого листа и Sprint 2 не сделан** — задача ниже.

### Sprint 2 · Path Diversity + Self-Heal

**E4 · Babel path ETX + feasibility** ([RFC 8966 §3.7](https://www.rfc-editor.org/rfc/rfc8966.html))
- ETX метрика per link
- Feasibility condition (loop-freedom)
- Файлы: `src/routing.rs` или новый `src/babel.rs`
- Unit tests: минимум 5 сценариев + 100-topology fuzz (0 loops)

**E5 · Ranked next-hops k=2** ([LB-OPAR arXiv:2205.07126](https://arxiv.org/abs/2205.07126))
- Топ-2 next-hop per destination, node-disjoint paths
- Hot-swap на `force_dead`
- Failover latency <300 ms
- Файлы: `src/router.rs`, `src/topology.rs`
- Unit tests: треугольник + diamond + случай k=2 недостижим
- **Осторожно с кэшем**: `ranked_candidates` HashMap должен инвалидироваться при `force_dead` (см. Bug A в истории)

**E6 · Self-heal thresholds**
- Instrument `link_loss_to_reroute_ms` и `node_off_to_reroute_ms`
- Emit JSON metrics on stdout
- CI gate: <5s link, <10s node
- Определить threshold в расширении `specs/wire.t27`, не хардкод
- Файлы: `specs/wire.t27`, `src/daemon.rs`, `src/health.rs`

### Acceptance criteria (жёсткие)

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

**Ветка:** любая локально, префикс `local/*` рекомендован. Я применю через `git am`.

---

## 5. Handoff-протокол

Когда Sprint 2 = 3/3 и acceptance зелёный:

1. Сгенерируй patch-серию:
   ```bash
   git format-patch <sha-of-base>..HEAD -o /tmp/sprint2-patches/
   # или mbox:
   git format-patch <sha-of-base>..HEAD --stdout > /tmp/sprint2-full.mbox
   ```

2. Обнови `docs/AGENT_STATUS_LOCAL.md` секцией:
   ```markdown
   ## Sprint 2 Handoff — <ISO timestamp>

   Status: ready for cloud apply
   Local head SHA: <sha>
   Base SHA: <sha>
   Tests: <N> passing, 0 failing
   Fuzz: 100/100 converged, 0 loops
   Clippy: clean
   Fmt: clean

   Patches (git-am format):
   <paste concatenated .patch files here>
   ```

3. **Пользователь-курьер (Dmitrii) копирует секцию в чат со мной.** Я применяю через `git am`, пушу, открываю draft PR.

**Если patch-серия > 200 KB** — упакуй в tarball, отдай через GitHub gist или прямое прикрепление файла пользователем. URL/имя файла напиши в `AGENT_STATUS_LOCAL.md`.

**Формат `AGENT_STATUS_LOCAL.md`** для регулярных апдейтов:
```markdown
## <ISO timestamp> — <краткий заголовок>

Что делаю сейчас: ...
Что закрыл: ...
Блокеры: ...
Вопросы к облачному: ...
Idle suggestions (если свободен): ...
```

---

## 6. Что можно без approval

- Любая работа в твоей локальной копии
- Любые ветки с любыми именами локально
- Любые эксперименты в `src/`, `tests/`, `smoke/`, `specs/`
- Обновлять `docs/AGENT_STATUS_LOCAL.md` (твой канал ко мне)
- Гонять `cargo test`, `cargo clippy`, `cargo fmt` без ограничений
- Локальные коммиты с префиксом `local/` в имени ветки

---

## 7. Жёсткие границы (не пересекать без явного зова)

**Не пытайся push/pull к origin** — у тебя нет токена, 404 гарантирован, силы зря.

**Не создавай `.github/*` templates** — это infrastructure change, требует approval пользователя.

**Не трогай (моя зона):**
- `docs/WAVE_REPORT_*.md`
- `docs/BENCHMARK_*.md`
- `docs/AGENT_ORDERS_*.md`
- `docs/AGENT_STATUS_CLOUD.md`
- `docs/AGENT_ONBOARDING.md` (этот файл)

**Не заявляй моё состояние** — ты не знаешь что у меня в облаке. Пиши только про свою локальную копию.

**Не работай над:**
- E1-E3 (Sprint 1 — уже смёржено)
- E7-E11 (Sprint 3-4 — жди приказа)
- Новые волны N+2/N+3 — жди явной команды пользователя

**Не флеши железо** (Zynq issue #8, PA/антенны issue #9) — human-only.

**Не мержь PR** — human-only.

**Не создавай ветки с date-суффиксом уровня wave** (типа `wave-n2-benchmark-2026-07-04`) — это моя нотация, конфликтует.

---

## 8. Правила честности (жёсткие)

- **4 dies SKY26b** — submitted (2026-07), returned silicon отсутствует. Никогда не заявляй returned без пруфа.
- **Trinity CLARA 1 GOPS @ 1W** — projected/pre-silicon. Всегда явно помечать.
- **Никаких выдуманных цифр** — «120 тестов», «68 T27 модулей», «ZedBoard $25K procurement» и подобное в прошлом было фабриковано. Не повторяй.
- **Никаких `cargo test` результатов из головы** — только реальный запуск с реальным stdout.
- **Каждая метрика в отчёте** — с источником: URL, файл в repo (`docs/X.md:line`), или явное «не найдено».
- **Разделяй measured / projected / target** — не путай.

---

## 9. Emergency procedures

**Если тесты падают:**
1. Не коммить сломанный код
2. Фиксить локально, перегонять `cargo test --all`, потом коммит
3. Документировать fail в `AGENT_STATUS_LOCAL.md` (что было, что сделал, что осталось)

**Если застрял:**
1. Проверить `AGENT_STATUS_CLOUD.md` — может быть новые инструкции от меня
2. Проверить последний `AGENT_ORDERS_2026-07-*.md`
3. Продолжать best-effort имплементацию
4. Документировать блокер в `AGENT_STATUS_LOCAL.md` для следующего handoff

**Если нужен push срочно:**
1. Убедиться `AGENT_STATUS_LOCAL.md` актуален
2. Закоммитить всё с descriptive message
3. Написать в `AGENT_STATUS_LOCAL.md`: `@cloud-agent: ready for push`
4. Ждать пользователя-курьера

**Если получил моё состояние через дамп сессии и оно противоречит твоему пониманию:**
- Не считай своё локальное состояние ложным автоматически
- Проверить факты через `git log`, `cargo test`, `git status`
- Написать в `AGENT_STATUS_LOCAL.md` разночтения с моим докладом — пусть пользователь-курьер разберётся

---

## 10. Success criteria

**Sprint 2 complete когда:**
- E4 · Babel path ETX + feasibility done (100 fuzz, 0 loops)
- E5 · Ranked next-hops k=2 done (<300 ms failover)
- E6 · Self-heal instrumentation done (CI gate <5s link, <10s node)
- Все тесты зелёные (>136 baseline + Sprint 2 новые)
- `AGENT_STATUS_LOCAL.md` показывает «Sprint 2: COMPLETE» с handoff-секцией
- Код запушен облачным агентом (draft PR открыт)

**M5 demo gate ready когда:**
- Sprint 1 (security) + Sprint 2 (path diversity) + Sprint 3 (audit ring) — все complete
- Measurable self-heal (<5s link, <10s node) — field-verified
- Benchmarks demonstrate resilience против MPU5/Silvus baseline

---

## 11. Параллельная работа

- **Cloud (я):** Wave N+2 β benchmark done (PR #22), Wave N+1 competitor analysis done (PR #20), weekly cron competitor-watch активен
- **Local (ты):** Sprint 2 done локально, next — WAIT MODE или следующий Sprint по приказу
- **Human:** review, merge PR, hardware operations

**No blocking:**
- Sprint 2 не блокирует Wave N+2
- Wave N+2 не блокирует Sprint 2
- Оба могут комплитить в любом порядке

---

## 12. Итог первой сессии

1. Прочитай этот файл целиком
2. Проверить статус Sprint 2 через `git log local/sprint2-path-diversity-2026-07-04` — если ветка есть и `cargo test --all` = 176/0, ты на пост-Sprint-2 стадии → WAIT MODE
3. Если ветки нет → начать Sprint 2 E4-E6 в своей копии
4. Писать прогресс в `docs/AGENT_STATUS_LOCAL.md`
5. Когда acceptance зелёный — handoff patch через пользователя
6. После handoff — WAIT MODE, жди следующего приказа

Оценка времени с чистого листа: 4-8 часов чистого кода + тестов + fuzz.

---

## Подпись

Perplexity Computer, cloud sandbox
Приказ №0 (onboarding), версия 2.0
Слияние: cloud 158-строчной (коммит `74dbbf5`) + local 210-строчной (коммит `7bad790`)
Дата слияния: 2026-07-04

φ² + φ⁻² = 3

Welcome aboard. Execute с честностью.
