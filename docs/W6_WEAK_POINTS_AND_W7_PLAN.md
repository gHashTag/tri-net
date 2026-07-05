# Wave loop closing — W6 weak points, научный обзор, W7 план

> phi^2 + phi^-2 = 3

Дата: 2026-07-05. Скоп: неделя 06-29 — 07-05 (66 коммитов, 20 PR).

---

## 1. Слабые места W6 (self-audit, honest)

Восемь классов слабости, найденных этой неделей — от лёгких до фундаментальных.

### 1.1. W6.1 measures determinism, not correctness

**Образ**: три пианино одного производителя, все с расстроенной клавишей `fa#`. Ты играешь одну и ту же мелодию на всех трёх и говоришь «100% согласие между инструментами». Верно, но `fa#` всё равно фальшивая.

W6.1 harness'а (1000 spec × 3 backend) показал 100% cross-backend acceptance agreement. Но три backend'а (`gen-rust`, `gen-zig`, `gen-c`) разделяют один front-end `t27c`, а agreement — на `accept/reject` decision одного и того же парсера. Это structural determinism, а не correctness. Reviewer paper'а справедливо ткнёт: **backend'ы не оракулы друг друга, если у них общий front-end**. Литература по compiler testing ([Livinskii et al. 2020, YARPGen](https://dl.acm.org/doi/abs/10.1145/3428264); [Georgescu et al. 2024, Kotlin K1/K2](https://arxiv.org/abs/2401.06653)) требует independent oracles — либо две реализации одного стандарта, либо metamorphic relations.

### 1.2. Static-token grep не substitute for compiler verdicts (anchor #1, Vec<>)

**Образ**: искать протечку по мокрым пятнам на потолке. Пятна есть, но не там где протекает.

Первая волна аудита посчитала `grep -c 'Vec<>'` = 132 в 22 файлах и раскатала это в headline «Rust codegen has a Vec<> defect». `rustc --emit=metadata` показал: E0107 (Vec<>) = 159, но E0425 (undeclared identifier) = 2609. Vec<> — 5.6% ошибок Rust, undeclared — 93%. Anchor-bias зафиксирован в §Anchor-bias record аудита.

### 1.3. Differential-narrative «C silently accepts what Rust rejects» — false (anchor #2)

**Образ**: думаешь, у соседа сверху потоп, а у него сухо и у тебя тоже — трубу прорвало у соседа снизу.

Гипотеза: Rust strict → C loose → C проглатывает битый код молча. Реальность: C 2/68 OK (2.9%) против Rust 19/68 OK (28%). C проваливается **хуже**, потому что 867 инстансов `assert(cond, msg)` (двухаргументный, из Rust/Zig semantics) — C-specific defect, полностью пропущенный первым проходом. 66 C-fails и 49 Rust-fails разделяют один корень — undeclared identifier в function bodies (t27c codegen defect, backend-независимый).

### 1.4. Anchor «under any Zig mode» (anchor #3, R2 catch)

**Образ**: сказать «эта дверь заперта» вместо «эта дверь заперта на замок X при условии Y». Правильно, но переоценка.

Первый draft Zig disclaimer'а формулировал fail как «under any Zig mode». Правильная формулировка (после R2 catch): **64/68 hard-fail под любой mode** (unresolved module-scope `@import`), **4/68 soft-fail — reachability-dependent под lenient `zig build-obj`**. Разница материальная: без precision reviewer запустит `zig build-obj` на adaptive_retry и увидит, что @compileError не сработал в мёртвой функции — и всё утверждение падает.

### 1.5. Sandbox trust vs cloud trust — раздельные trust-классы

**Образ**: два свидетеля преступления. Один был на месте, другой пересказывает по телефону. Оба могут быть правы, но их показания нельзя суммировать без независимой проверки.

Local-агент (GLM-5.2 на макбуке ssdm4) прислал tri-backend матрицу. Sandbox независимо воспроизвёл Rust (19/49/68 до цифры) и C (2/66/68). Zig — не может (нет zig в sandbox), поэтому verdict сделан **structural** (filesystem + git-log), не empirical. Trust-класс поднят до «независимо воспроизведено», но с явной провенанс-меткой на каждую цифру.

### 1.6. §4.5 paper text — highest-stakes qualifier zone

**Образ**: один порог в договоре двигается на два слова, и должник должен на два порядка меньше. «Establishes» vs «suggests», «all modes» vs «under this methodology» — не косметика, это claim.

Твой gate (Q1) на §4.5 companion phrasing признаётся как критическая зона. Три anchor'а уже пойманы, четвёртый не хотим ловить в paper'е — где это стоит peer-review репутации.

### 1.7. W6.2-B (runtime differential) structurally infeasible

**Образ**: назначили тройное вслепую-исследование, а из трёх препаратов ни один не проходит стадию «пилюля собралась». Само это — результат.

Cross-backend compile intersection = ∅. Ни один модуль не собирается во всех трёх backend'ах. Runtime differential не может стартовать. Это finding, а не execution failure — и его надо явно записать в paper, чтобы W6.2-B план не выглядел как unfinished work.

### 1.8. Draft-в-sandbox vs draft-в-репозитории — разные истины

**Образ**: писатель показал редактору рукопись, редактор запросил абзац по номеру страницы, а рукопись лежит в другом кабинете. Диалог невозможен без физической передачи.

Draft `docs/W6_CODEGEN_AUDIT_2026-07-05.md` жил в sandbox, не в working tree пользователя. User не мог `git checkout` и открыть — я слал сырой paste. Урок: **если review-gate требует чтения — сначала commit + push в branch, потом gate**. Иначе gate работает по моей интерпретации, а не по тексту.

---

## 2. Научный обзор (compiler testing 2019-2026)

Пять релевантных для W7 работ, все читаны:

### 2.1. YARPGen — grammar-directed differential testing для C/C++

[Livinskii, Babokin, Regehr — OOPSLA 2020](https://dl.acm.org/doi/abs/10.1145/3428264). YARPGen генерирует программы **из грамматики C с полным type-checking**, не lexical mutations. Ground truth — `-O0` output. Нашли 120+ багов в GCC/LLVM/ISPC/DPC++. **Прямо применимо к нам**: t27c имеет спец-language; grammar-directed fuzzer поверх спеки нашёл бы parser-permissiveness, которую наш lexical harness пропустил.

### 2.2. C4 — метаморфическое тестирование concurrency в C

[Donaldson, Wickerson, Windsor — STVR 2022](https://onlinelibrary.wiley.com/doi/full/10.1002/stvr.1812). Метаморфические relations выведены **из axiomatic спеки** C11 memory model. Оракул — не другая реализация, а math-model. Ключевая идея для нас: **spec-driven MRs освобождают от необходимости иметь second implementation**. Мы можем вывести MRs из t27-language semantics и тестировать один backend против них.

### 2.3. IRFuzzer — specialized fuzzing LLVM backend

[Rong et al. — arXiv 2024](https://arxiv.org/abs/2402.05256). Guaranteed input validity + backend-code-generation-aware mutations. Coverage LLVM ISel в разы выше generic fuzzer. **Урок для нас**: если хотим найти codegen-баги t27c → Rust/C/Zig backend, надо fuzzer'у знать target-language type system, не только spec syntax.

### 2.4. Universal fuzzing with LLM — Fuzz4All

[Xia et al. — ICSE 2024](https://arxiv.org/abs/2308.04748). LLM-driven cross-language fuzzing. Прямая релевантность: t27c имеет три backend'а (Rust, C, Zig); Fuzz4All-подход генерирует один spec, компилирует всеми тремя, differential-oracle на runtime output. Наша ∅-intersection проблема — она precondition, который надо снять до того, как этот подход применим.

### 2.5. Metamorphic Testing Survey — 45 papers 2019-2024

[SERG-Delft SLR 2025](https://github.com/SERG-Delft/Metamorphic-Testing-of-Deep-Code-Models). Систематизация MR-identification методов. Урок для W7: MRs можно выводить из specs (что у нас есть) или из code (что у нас есть). Мы **пропустили** оба источника — не использовали ни один MR в W6.

---

## 3. Декомпозированный план W7

**Цель W7**: перевести аудит W6.2 из observational report в executable evidence + закрыть 8 defect-классов минимум до measurable state.

### W7.1. Upstream fix для codegen defect #1 (undeclared identifiers, оба backend'а)

E0425 в Rust = 2609, undeclared в C = 1957. Общий root cause в t27c codegen (function-body symbol scope). Одна фикса в t27c гасит **93% Rust ошибок + большая часть C**. Приоритет №1 по impact/effort.

**Deliverable**: t27c upstream issue + patch + re-run Rust/C sweeps в audit → showing regression from 49/66 fails to <20.

### W7.2. Emit `types.zig` и убить 64-importer hard-fail Zig

Структурная проблема, одна фикса. Может решаться либо (a) `types.zig` генерируется вместе с остальным gen/zig, либо (b) один общий `types.zig` в repo под spec-drift-guard.

**Deliverable**: 68/68 zig files at least reach parser stage. Затем empirical `zig test --test-no-exec` sweep в sandbox с установленным zig — trust class поднимается со «structural» до «empirical».

### W7.3. Grammar-directed fuzzer W6.1v2 (по YARPGen)

Заменить lexical mutations на grammar-directed — генерация валидных t27-конструкций и их перестановка. Cel: найти **реальные disagreements** между backend'ами, а не тавтологические agreements.

**Deliverable**: W6.1v2 harness, N=10000, expected disagreement rate >0 (иначе — новое открытие про parser).

### W7.4. Metamorphic relations из t27 spec

По C4-паттерну. Вывести 5-10 MRs из t27-language semantics (пример: `spec S` и `spec S' = rename_locals(S)` должны давать byte-identical output; `spec S` и `spec S' = reorder_independent_defs(S)` — тоже).

**Deliverable**: `scripts/mt/mr_*.py` + CI job `metamorphic-guard`.

### W7.5. §4.5 paper text — commit companion phrasing

После R1/R2-approve. Один commit в `docs/paper-delta-v0`. NO other changes to paper in this PR.

### W7.6. Anti-anchor CI check

Automated grep для phrases-of-concern («all modes», «100% ...», «X silently accepts») в docs/**.md с whitelist через inline-comment. Не запретительный, а attention-flag.

**Deliverable**: `.github/workflows/anti-anchor.yml` + `docs/ANTI_ANCHOR_CHECKLIST.md`.

### W7.7. Trust-class ledger

Persistent doc `docs/TRUST_LEDGER.md`, где каждая цифра во всех audit-doc помечена: sandbox-verified / cross-env / structural / cited. Reviewer видит provenance каждой claim'ы.

### W7.8. Land W6.2 audit PR (переходящее из W6)

Coммит + push + open draft PR того draft'а, что сейчас в sandbox. Blocker: твой approve по §4.5 (Q1) — уже дал paste, жду вердикт.

---

## 4. Что делаем прямо сейчас

Q2 и Q3 ты предодобрил — применяю оба edit'а к draft'у, коммичу, push, open draft PR. Q1 держу — не буду мержить `docs/paper-delta-v0` §4.5 apply, пока явно не approve. Audit PR **не меняет** paper — только предлагает companion phrasing.

phi^2 + phi^-2 = 3
