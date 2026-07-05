# Wave Report — неделя 2026-06-29 → 2026-07-05

> phi^2 + phi^-2 = 3

**Скоп**: 66 коммитов, 20 PR (5 merged, 8 draft open, 1 closed), 3 автора (Perplexity Computer sandbox, Vasilev Dmitrii, ssdm4 macbook).

**Метрика активности**: 36 docs / 22 feat / 6 ci / 3 fix / 1 test.

---

## Часть 1. Хронология по волнам

Неделя укладывается в **шесть волн**. Каждая — отдельный research-episode с фалшь-стартом, коррекцией и bedrock'ом. Ниже — картинка каждой.

### Волна 1 (07-01 → 07-02) — импорт trios-mesh, T27 attempt №1 на wire

**Образ**: библиотекарь получает три ящика книг разного размера и должен уложить их на общую полку.

Коммиты: `ddd8c16` (initial README), `4743a86` (import trios-mesh codebase), `116fa97` (port wire.rs → specs/wire.t27).

Первая попытка T27-first flip'а на модуле `wire`. Осознание: bit-shift lowering ломается — но это ложная гипотеза, реальность (найдена позже) — missing ExprCast (`daeae62`, `880954e`). Первый anchor-bias эпизод недели.

### Волна 2 (07-03) — координация с local-агентом, sprint 2 recovery

**Образ**: два капитана одного корабля с разными картами.

Коммиты: `5ea4c49`, `f7efdc5`, `2e72e35`, `76a972e`, `4da6e85`, `74dbbf5` — orders #1-4 + onboarding brief для local-агента. `6076c8f` — E4-E6 path diversity + self-heal (Sprint 2 recovery после mbox-loss).

Установлен **coordination protocol**: local не пушит напрямую, все pushes через cloud-агент, no-push reality → mbox handoff. Wave N+2 β военно-технический benchmark vs MPU5/Rajant/Silvus (`2466168`).

**Научная параллель**: [Georgescu et al. 2024, Evolutionary Generative Fuzzing for Kotlin K1/K2](https://arxiv.org/abs/2401.06653) — двухкомпилятор differential как оракул. У нас role differential — **два разных агента** (local vs cloud), одна кодовая база, differential trust classes. Тот же паттерн другого масштаба.

### Волна 3 (07-04) — DePIN pivot + M1 IP policy + arXiv δ-paper

**Образ**: физик, который переключил тему PhD с квантовой оптики на quantum sensing, потому что там больше грантов — но с сохранением всех прежних инструментов.

Коммиты: `c66d7cc` (README DePIN pivot), `52c006f` (M1 scientific closure + image-bake + persistent-IP policy), `dcdbd1b` (25 host-only pure-logic tests), `7d6689c` (P203 Mini as four-armed DePIN node), `6f508db` (arXiv-draft MANET vendor auditability gap), `af1dd57` (triangle-protocol L0-L4 measurement spec).

Стратегический сдвиг: tri-net позиционируется не как «MANET vendor», а как «reproducibility-first DePIN infrastructure». δ-paper skeleton выложен (`178608a`).

### Волна 4 (07-04, вечер) — Wire flip #2 + spec-drift-guard

**Образ**: SSOT triangulation. Одна источник истины (spec), три производные (Rust, C, Zig gen), CI проверяет byte-identity ежепушно.

Коммиты: `a6bb0b0`, `77a9a49` (wire T27-first flip #2, правильный), `78c29ba` (regenerate с real ExprCast lowering), `f126dca` (spec-drift-guard v1 для wire.rs), `dc1bebb`, `b60fdc9` (extend guard to Zig+C — 3 backend'а).

Bedrock #1: **byte-identity CI**. spec-drift-guard PR #38 merged. Гарантирует что `t27c(specs/X.t27)` = `gen/{rust,zig,c}/X.*` до последнего байта на каждом PR, касающемся `specs/`.

**Научная параллель**: [CompCert verified compilation](https://xavierleroy.org/courses/DSSS-2017/slides.pdf) — не formal verification, но самая слабая форма translation validation. У нас нет доказательства, что output правильный — только доказательство, что output стабильный. Слабее CompCert, сильнее чем reproducible-build guarantee.

### Волна 5 (07-04 ночь → 07-05 утро) — MEGA batch t27-flip 68/68

**Образ**: перевод библиотеки с одного языка на три параллельных языка.

Коммиты (16 flip'ов): от `c29bf2d` (hello.t27 + etx.t27, specs 1-2) через `446ccde`, `1d6fd92`, `16cd750`, `06e63b9`, `22c0942`, `fa4702e`, `8a1ce1f`, `a042d38`, `9377d2b` (final 6 specs → 68/68).

`815e21b` импортировал 67 .t27 specs из local Wave work. К концу волны — **68/68 specs SSOT, 204 drift-checks (68 × 3 backend), 100% coverage** (`be70505`).

Это выглядело как громкая победа. Волна 6 показала иначе.

### Волна 6 (07-05) — strategic audit → W5 bench → W6.1 fuzz → W6.2 codegen audit

**Образ**: три последовательных reality-check'а. Каждый показал, что предыдущий headline слабее, чем звучал.

Коммиты: `73e5d18` (strategic audit — 7 findings + 3 options), `bf50ad6` (W5 bench harness — real measurements), `af9f48c` (paper §5.5 real numbers), `6768637` (W6.1 structural fuzz 100%, PR #41).

**Reality-check #1** — strategic audit: 68/68 SSOT — но `wire` был единственным модулем с полной test-парой; 24 spec-функции имеют stub'ы в трёх backend'ах с ТРЕМЯ разными policy of failure (Zig `@compileError` compile-time, Rust `panic!` runtime, C silent UB / TODO). Симметрия 24:24:24 — не decorative, это policy-divergence-под-одинаковой-обёрткой.

**Reality-check #2** — W5 bench: paper §5.5 писался под предположения «Rust encode-round-trip 700ns» — реальность в bench harness (`bench/harness/`) была `wire` = ~1.2μs mean, coefficient of variation 8%. Разница между «7% CoV из головы» и «8% CoV из измерений» — не ужасная, но обязательная переписать §5.5 (`af9f48c` сделал это).

**Reality-check #3** — W6.1 fuzz: 100% cross-backend agreement на 1000 spec'ах, N=3000 subprocess calls, 5.0 сек. Побочное открытие: t27c permissive на lexical-injuries (`u8→u9`, drop-`;`, `return→returnn`, `->→=>` все проходят). Fuzzer только «drop-close-brace» ловит. Значит W6.1 headline «100%» технически верен, но **operationally hollow** — все три backend делят один парсер, agreement почти тавтологичен.

**Reality-check #4** — W6.2 codegen audit (сегодня, PR #42): tri-backend compile matrix 19/49/68 Rust, 2/66/68 C, 0/68 Zig, cross-backend OK ∩ = ∅. Ни один модуль не собирается во всех трёх. W6.2-B (runtime differential) structurally infeasible.

**Научная параллель волны 6**: [Livinskii et al. 2020, YARPGen](https://dl.acm.org/doi/abs/10.1145/3428264) — differential testing работает, только если backend'ы независимы. У нас три backend'а разделяют один front-end (`t27c`); agreement не является oracle-signal. YARPGen нашёл 120 багов в GCC/LLVM/ISPC/DPC++ **потому что** это независимые реализации одного стандарта. Наш «tri-backend» — эмиссионные ветки одного codegen'а, а не независимые реализации.

---

## Часть 2. Три anchor-bias эпизода — сами по себе научный результат

Три эпизода, каждый — case study в static-analysis illusion:

### Anchor #1: `grep 'Vec<>'` → «Rust codegen has a Vec<> defect»

Первичный поиск: `grep -c 'Vec<>' gen/rust/*.rs` → 132 в 22 файлах. Framing: «главный Rust codegen defect».

Реальность после `rustc --emit=metadata`: E0425 (undeclared) = 2609, E0107 (Vec<>) = 159. Vec<> = 5.6%, undeclared = 93%. Static grep пропустил доминирующую ошибку в 16 раз.

**Урок**: static-token grep — это не substitute для compiler verdict, даже приближённого.

### Anchor #2: «C silently accepts what Rust rejects»

Первичная гипотеза (differential-narrative): Rust strict → C loose → C проглатывает битый код молча.

Реальность после `cc -c -std=c11 -Wall -Wextra`: C 2/68 OK, хуже Rust 19/68. 66 C-fails и 49 Rust-fails **разделяют один корень** — undeclared identifier из t27c codegen. C дополнительно ломается на 867 `assert(cond, msg)` (двухаргументный, из Rust/Zig semantics — 7-й, полностью пропущенный класс).

**Урок**: если два инструмента показывают проблемы разных типов, это ещё не значит, что root causes независимые. Root cause может быть общий и глубже обоих.

### Anchor #3: «under any Zig mode»

Первичная формулировка draft'а Zig-verdict: fail «under any mode». Reviewer catch (R2): 64 файла — hard-fail под любую mode (unresolved module-scope `@import`), но 4 файла — soft, reachability-dependent под lenient `zig build-obj` (lazy analysis может пропустить `@compileError` в мёртвой функции).

Precise version в PR #42: **64 hard + 4 soft под test mode + 0 pass под test --test-no-exec (cross-env empirical)**. Разница материальная — reviewer с 30 секундами и `zig build-obj adaptive_retry.zig` мог бы разорвать формулировку.

**Урок**: overclaim в компиляторных verdict'ах есть особый вид anchor-bias. Разница между «under any mode» и «under mode X» — не косметика.

---

## Часть 3. Bedrock артефакты недели (то, что переживёт W7)

Всё, что осталось после reality-check'ов и того, что паснёт peer-review:

1. **spec-drift-guard CI** ([PR #38 merged](https://github.com/gHashTag/tri-net/pull/38)) — byte-identity enforcement для 68 × 3 = 204 drift checks. Слабейшая, но реальная форма translation validation.

2. **68/68 specs SSOT** ([bf50ad64 on PR #39](https://github.com/gHashTag/tri-net/pull/39)) — 68 t27-модулей, каждый lowered в Rust + C + Zig текстово-детерминированно. Correctness — отдельно, это output-stream determinism.

3. **W5 real bench** (paper §5.5, `af9f48c`) — реальные измерения `wire` encode/decode round-trip: ~1.2μs mean, 8% CoV. Не спекуляция.

4. **W6.1 structural fuzz** ([PR #41](https://github.com/gHashTag/tri-net/pull/41)) — 1000 spec × 3 backend, 100% cross-backend acceptance agreement. **Reframe**: measures determinism-under-shared-parser, не structural correctness.

5. **W6.2 codegen audit** ([PR #42](https://github.com/gHashTag/tri-net/pull/42)) — tri-backend compile matrix, empty intersection, 8-class defect taxonomy, anchor-bias self-errata. **Главный negative result недели, зафиксирован документально**.

6. **Triangle protocol L0-L4 spec** (`af1dd57`) — publick measurement spec, reproducibility-first framing.

7. **arXiv δ-paper skeleton** ([PR #36 draft](https://github.com/gHashTag/tri-net/pull/36), afiiliation `docs/paper-delta-v0`) — spec-first + reproducible-HDL позиционирование. §5.5 обновлён под W5 real numbers. §4.5 — под companion phrasing из W6.2 audit, но не применён (жду approve).

---

## Часть 4. Что не переживёт

- **W6.2-B runtime differential** — cancelled. Empty compile intersection не даёт стартовой площадки. Записано как finding в PR #42.
- **«Vec<> — главный Rust дефект» narrative** — replaced. Anchor-bias record в §Anchor-bias record W6.2 audit.
- **«C silently accepts» narrative** — replaced аналогично.
- **W6.1 «structural correctness» framing** — reframed в «determinism under shared parser» через W6.2 §Section 4.5 reconciliation.

---

## Часть 5. Провенанс всех цифр

| Цифра | Метод | Trust class | Reproducibility |
|---|---|---|---|
| Rust 19/49/68 OK/FAIL | rustc 1.93.1 --emit=metadata | sandbox verified + cross-env verified | `bash scripts/audit/rust_compile_sweep.sh` |
| E0425 = 2609 | rustc grep | sandbox | same script |
| C 2/66/68 OK/FAIL | cc -c -std=c11 -Wall -Wextra | sandbox verified + cross-env verified | `bash scripts/audit/c_compile_sweep.sh` |
| assert 2-arg = 867 | grep of cc stderr | sandbox | same |
| Zig 64 importers | grep of gen/zig/*.zig | sandbox filesystem + git-log --all | `bash scripts/audit/zig_static_check.sh` |
| Zig 4 stub-bearing | grep @compileError | sandbox | same |
| Zig 0/68 empirical | zig test --test-no-exec | cross-env only (macbook ssdm4, zig 0.15.2) | not sandbox-reproducible without zig install |
| W5 bench 1.2μs / 8% CoV | criterion-rs on wire | sandbox | `cargo bench --package wire` (см. `bench/`) |
| W6.1 100% / 1000 specs | run_fuzz.py N=1000 | sandbox | `python scripts/fuzz/run_fuzz.py --n 1000 --seed 0xF1F1F1F1` |
| 68/68 SSOT | spec-drift-guard CI | sandbox + CI verified | CI job on PR touching specs/ |

Каждая цифра в audit doc и в этом отчёте линкует либо в script (reproducible в sandbox), либо в PR (linked commit hash), либо помечается cross-env (провенанс раскрыт).

phi^2 + phi^-2 = 3
