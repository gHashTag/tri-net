# Wave 2026-07-11 v3 — аудит 9 never-audited модулей (mesh_routing, etx, adaptive_routing, multipath_routing, frame_buffer, flow_control, health_dashboard, anomaly_detector, quarantine_manager)

Дата: 2026-07-11. Ветка: `feat/wave-report-2026-07-11-v3`. Тип: audit + plan (без имплементации).

Область волны: 9 сгенерированных модулей, впаянных в `src/lib.rs` (строки 21-46) с `#[path=...]` и не разбиравшихся ни одной прошлой волной, плюс их спеки `specs/*.t27`.

## 1. Честное предисловие (проверено командами, не по памяти)

- `main` красный. Проверено: `cargo build` в чистом клоне (`git HEAD 6850649`) падает в `build.rs` первым же — `error[E0308]` + `error[E0599] no method map_or`. Это уже зафиксировано в прошлых волнах и в незамёрдженном PR #60 — здесь НЕ переотчитывается.
- Заземление счётчиков (не по памяти): `find specs -name '*.t27' | wc -l` = 68; `grep -rE '^\s*#\[test\]' src tests gen | wc -l` = 101; `test`-блоков в спеках = 640; `grep -cE '^\s*pub mod' src/lib.rs` = 17.
- Ключевой факт волны, подтверждённый компилятором (`rustc 1.95.0`, каждый файл собран отдельно `rustc --edition 2021 --crate-type lib`):
  - `mesh_routing.rs` — компилируется чисто (только консты + две простые функции, локальных `let` нет).
  - `etx.rs`, `frame_buffer.rs` — парсятся, но не проходят typecheck (`E0308`/`E0369`): `as`-каст в codegen превращён в `()`.
  - `adaptive_routing`, `multipath_routing`, `flow_control`, `health_dashboard`, `anomaly_detector`, `quarantine_manager` — НЕ парсятся: `error: expected pattern, found ';'` (по 12-47 раз на файл, всего 176 битых `let;`).
- Корневая причина этих rustc-ошибок (dropped-`let`, `as`→`()`, `[T;N]`→`Vec<>`) — уже задокументирована и трекается апстримом: PR #44 (t27#1401 «Rust emitter drops all let»), issue #61 (t27#1456 optimizer-removal + t27#1457 array/index codegen). Поэтому сам codegen-дефект здесь НЕ засчитывается как новая находка. Новое в этой волне — спек-уровневые логические баги, которые переживут фикс codegen (см. §3). Также НЕ переотчитываются пункты issue #61: `multipath:128 == path_valid ==`, `is_multipath_viable` bool/u32, `etx:45 256-alpha`, let-vs-var E0384, dead-code warnings.

Метафора «замок и стены»: стены (9 модулей security/routing) выглядят достроенными на чертеже (спеки), но ворота заклинило на этапе отливки (codegen) — снаружи не видно, что в самих чертежах ещё и петли посажены криво (спек-баги ниже). Отдельно чинить петли надо даже после того, как ворота начнут открываться.

## 2. Тепловая карта слабых мест (только НОВОЕ; codegen-строка — контекст, не находка)

| # | Слабое место | Sev | Файл:строка | E-id |
|---|---|---|---|---|
| C0 | (контекст, НЕ ново) codegen: 8/9 модулей не собираются даже после фикса build.rs — dropped-`let`/`as`→`()`/`[T;N]`→`Vec<>` | P0 | `gen/rust/*.rs`; трек PR #44, issue #61, t27#1401/#1456/#1457 | — |
| W1 | `detect_anomaly`: `TYPE_SPIKE = 0` совпадает с sentinel «нет аномалии»; финальный гейт `if (anomaly_type != 0)` глушит ВСЕ spike-аномалии — самый базовый и атако-значимый класс не репортится никогда | P1 | `specs/anomaly_detector.t27:62,249,266` | E1.1 |
| W2 | flow_control: `MSG_CREDIT_UPDATE` → `update_credits` без клампа к window (клампит только `add_credits`); далее `window - credits` даёт u32-underflow → ложный вечный backpressure + мусорный `credit_grant` соседу. Триггерится удалённым сообщением | P1 | `specs/flow_control.t27:149,37,85,99,171` | E1.2 |
| W3 | quarantine_manager: `start_time` пакуется в 8 бит (`& 0xFF`, макс 255), а `QUARANTINE_DURATION = 1000`; `elapsed = current_time - start_time` не измеряет реальное время → карантин снимается не вовремя (рано/никогда), при `current_time < stored` — u32-underflow → мгновенный релиз. Тот же класс, что известный self_healing 8-бит cooldown, но ДРУГОЙ модуль | P2 | `specs/quarantine_manager.t27:16,29,90` (+ `ban_node` 0xFFFF→14 бит `:81`) | E2.1 |
| W4 | adaptive_routing: `calculate_score` = `255 / latency` (и `255 / hops`) — целочисленное деление даёт крайне грубые ступени (latency 200 и 255 → оба 1); `find_best_path` со строгим `>` держит первый такой → системный сдвиг выбора к path index 0 | P2 | `specs/adaptive_routing.t27:82,87,101` | E2.2 |
| W5 | multipath `distribute_load`: старт round-robin `% total_paths` (стр.154), а ретрай `% 4` (стр.164) — несогласованный модуль; при неконтигуозных валидных слотах старт может проскочить валидный путь | P2 | `specs/multipath_routing.t27:154,164` | E2.3 |

Метафора «тепловая карта»: горячее — W1/W2 (security-модули молча не срабатывают либо срабатывают ложно от удалённого триггера); тёплое — W3/W4/W5 (containment-таймер и качество метрик). C0 — раскалённый фон, но это чужой (апстримный) пожар, уже под наблюдением.

Метафора «что я реально нашёл в коде»: спеки написаны аккуратно (`let count = 0;`), а вот отливка их калечит — но даже почини отливку, три двери (W1/W2/W3) всё равно открываются не той стороной.

## 3. Наука → предписание

- W1 (anomaly spike sentinel). Модуль реализует 3-сигма-порог (`variance * 3`, `detect_spike`) — классический Shewhart/3σ control chart ([NIST/SEMATECH e-Handbook 6.3.2](https://www.itl.nist.gov/div898/handbook/pmc/section3/pmc32.htm)). Баг не в статистике, а в in-band sentinel: значение `0` служит и валидным типом (SPIKE), и «ничего». Предписание: зарезервировать out-of-band «нет аномалии» (например возвращать флаг валидности отдельно, либо перенумеровать типы с 1) и заменить гейт `anomaly_type != 0` на явный `detected`-флаг. Критерий: синтетический spike → `detect_anomaly` возвращает ненулевой report.
- W2 (credit underflow). Инвариант credit-based flow control: `credits <= window` всегда ([Kung & Morris, Credit-Based Flow Control for ATM Networks, IEEE Network 1995, DOI 10.1109/65.372658](https://doi.org/10.1109/65.372658)). Предписание: кламп `new_credits = min(new_credits, window)` внутри `update_credits` (а не только в `add_credits`); `used`/`credit_grant` считать через saturating-вычитание. Критерий: `MSG_CREDIT_UPDATE(credits>window)` не приводит к `used >= BACKPRESSURE_THRESHOLD`.
- W3 (quarantine timer). Сравнение обёрнутых счётчиков/времени — [RFC 1982 Serial Number Arithmetic](https://www.rfc-editor.org/rfc/rfc1982). Предписание: расширить поле `start_time` (или хранить дельту-таймер), сравнивать wrap-safe; согласовать ширину поля с `QUARANTINE_DURATION`. Критерий: карантин, начатый при `current_time > 255`, снимается ровно через 1000 тиков.
- W4 (coarse metric). ETX-урок: грубая метрика реинтродуцирует hop-count-вырождение и нестабильность выбора пути ([De Couto et al., A High-Throughput Path Metric for Multi-Hop Wireless Routing, MobiCom 2003, DOI 10.1145/938985.938995](https://doi.org/10.1145/938985.938995)). Предписание: считать score в Q8.8 (как уже сделано в `etx.t27`), а не `255/x`. Критерий: `find_best_path` различает latency 200 и 255.
- W5 (modulus). Согласовать оба модуля round-robin с числом активных путей и гарантировать progress по всем 4 слотам; ориентир по избеганию петель/feasibility — [Babel RFC 8966](https://www.rfc-editor.org/rfc/rfc8966). Критерий: `distribute_load` с валидными слотами {0,3} корректно выдаёт 3.

## 4. Обновление по конкурентам (1 строка)

Поле уходит в интегрированную multi-layer security прямо на MAC для ресурс-ограниченных UAV-роёв: [«Hybrid MAC Protocol with Integrated Multi-Layered Security for Resource-Constrained UAV Swarm Communications», arXiv:2510.10236, окт 2025](https://arxiv.org/pdf/2510.10236) — тогда как security-модули Tri-Net (quarantine/anomaly) пока inert-theater спеки с логическими багами W1/W3, что расширяет разрыв.

## 5. План на 4 спринта (только план; фиксы — спек-only, имплементация вне этой волны)

- Спринт 1 — корректность новых security-багов. E1.1 (spike sentinel, `anomaly_detector.t27`) + E1.2 (credit clamp/saturating, `flow_control.t27`). Acceptance: после апстрим-codegen фикса + regen — спек-тест на spike возвращает report; спек-тест на `credits>window` не даёт underflow. Effort: S.
- Спринт 2 — containment-таймер и path-diversity. E2.1 (quarantine start_time ширина/wrap-safe) + E2.3 (multipath modulus). Acceptance: release ровно через 1000 тиков при `current_time>255`; `distribute_load` на неконтигуозных слотах корректен. Effort: S.
- Спринт 3 — качество метрики. E2.2 (adaptive score в Q8.8). Acceptance: `find_best_path` различает соседние latency-значения выше 128. Effort: M.
- Спринт 4 — verification parity (gated на апстрим t27#1401/#1456/#1457). Впаять 9 модулей зелёными + добавить новые спек-тесты как компилируемые `#[test]` в CI; сверка gen↔spec. Acceptance: `cargo test -p trios-mesh` компилируется, тесты 9 модулей исполняются. Effort: M. Блокер: внешний codegen.

## 6. Три линии кооперации (для Wave N+1)

Линия A — Spec-correctness PR.
- Scope: правки W1/W2/W3 в трёх `.t27` + спек-тесты.
- Actor: автор спеков со знанием Rust-семантики.
- Deliverable: PR, редактирующий `anomaly_detector.t27`, `flow_control.t27`, `quarantine_manager.t27`.
- Cite: этот отчёт; Kung&Morris 1995; RFC 1982.
- Effort: ~0.5 дня. Risk: низкий; compile-верификация gated на codegen (Линия B).

Линия B — Upstream codegen liaison.
- Scope: довести t27#1401 (dropped-let) + t27#1456 (optimizer) + t27#1457 (array/index) до мёрджа, затем regen tri-net.
- Actor: разработчик компилятора t27c.
- Deliverable: мёрдж t27c-фикса + пересборка `gen/rust/`.
- Cite: PR #44, issue #61.
- Effort: неизвестно (внешний таймлайн). Risk: единственная точка блокировки всего трека.

Линия C — Detection-модуль test harness.
- Scope: добавить `test`-блоки, ловящие W1/W2/W3 (spike-detected, credit-overflow, quarantine-timeout) — регрессия после фикса codegen.
- Actor: QA/тест-инженер.
- Deliverable: `test`-блоки в трёх спеках.
- Cite: NIST/SEMATECH 6.3.2; RFC 1982.
- Effort: ~0.5 дня. Risk: `test`-блоки пока не лоуерятся в Rust — исполнятся только после codegen.

## 7. Граница (что эта волна НЕ делает)

- Только audit + plan. Ни одна спека/код не изменялись; фиксы не имплементированы (модули inert, `main` красный).
- Codegen-дефект (C0) — апстримный/внешний, не чинится здесь.
- Никакого железа, никаких owner-gated crypto (handshake N3-N5, PR #63/#65) не касались.
- PR — только draft, не мёрджить; в `main` не пушить (`docs/AUTONOMOUS.md`).

---

phi^2 + phi^-2 = 3
