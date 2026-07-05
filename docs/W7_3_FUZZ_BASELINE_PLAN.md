# W7.3 — Grammar-directed fuzz baseline

Status: **PLAN** (2026-07-05) — awaiting first generator commit.
Branch: `w7/testing/fuzz-baseline`.
Parent: W6.1 lexical fuzzer (`tests/fuzz/` — token-level, tautological на shared front-end).

## Задача

Заменить lexical fuzzer (W6.1, weak-point 1.5 из `W6_WEAK_POINTS_AND_W7_PLAN.md`) на **grammar-directed generator** в стиле YARPGen. W6.1 генерировал token streams и проверял, что parser не panic'ает — 100% agreement был тавтологией, потому что все три backend'а (Rust / C / Zig) шарят один front-end. Реальная differential мощь возможна только после того, как:

1. Генератор эмитит **валидные по grammar** программы (не token noise).
2. Round-trip harness проверяет структурную инвариантность parser'а.
3. Backend-differential применяется на well-typed inputs, где расхождение = семантический bug, а не parse-noise.

## Scope W7.3

Три этапа:

### E1 — Grammar-directed generator (первый коммит)

- `tests/fuzz/grammar_v2/generator.rs` — production rules с weighting.
- Grammar покрытие minimum:
  - `Module { UseDecl* ConstDecl* FnDecl+ }`
  - `FnDecl { name, params, ret_type, body }`
  - `Stmt ::= Let | Return | If | ExprStmt`
  - `Expr ::= Literal | Ident | BinOp | Cast | Call | Index`
  - Types: `u8 | u16 | u32 | u64 | usize | bool`
- Depth-bounded generation: max depth 6, max stmt count 20.
- Seed-reproducible через `StdRng::seed_from_u64`.
- Output: N=1000 генераций в `target/fuzz/w7_3/*.t27`.

### E2 — Round-trip harness (второй коммит)

- `tests/fuzz/grammar_v2/roundtrip.rs`:
  1. Gen spec → parse через `t27c` → AST.
  2. Pretty-print AST → source.
  3. Re-parse pretty-printed → AST'.
  4. Structural equality AST == AST' (модулю span'ов).
- Metric: `parse_fail_rate`, `roundtrip_fail_rate`, `panic_rate`.
- Failure classification: parse-error / ast-mismatch / panic / timeout.

### E3 — Backend differential (третий коммит, зависит от W7.1 upstream fix)

- Same input → `t27c gen rust|c|zig` → compile → runtime output.
- Differential trigger: any two backends диверджируют на same seed.
- **Caveat**: E3 валиден только когда upstream Stmt::Let fix у t27c приземлится. До этого gen/rust не имеет `let`, дифференциал структурно infeasible (см. W6.2 audit §3-5).
- Пока E3 blocked, E1+E2 работают независимо на current tree.

## Baseline run

Первый full run после E1+E2:
- N=1000 генераций.
- Distribution по (depth × stmt-count) — гистограмма в `docs/W7_3_FUZZ_BASELINE.md` (post-E2 doc, отдельный PR).
- Grammar coverage: доля production rules, exercised хотя бы одной генерацией.

## Success criterion

E1+E2 baseline считается **зелёным**, если:
- 100% валидных по grammar генераций parse'ятся без ошибок.
- ≥95% round-trip'ов структурно equal (allowed slack — pretty-printer whitespace normalization).
- 0 panics в t27c parser.

Любое отклонение — bug в parser или в pretty-printer, файлится как t27c issue (не tri-net) с seed'ом воспроизведения.

## Caveats и honest scope

- **Codegen-only vs parser-side ambiguity**: baseline валиден пока upstream Stmt::Let fix остаётся codegen-only. Если maintainer t27 определит проблему как parser-side (маловероятно — spec содержит `let`, значит parser их видит), baseline придётся пересобрать: parser может уже сейчас терять information, которую мы предположительно проверяем round-trip'ом.
- **Not a differential test** до E3. E1+E2 только проверяют parser self-consistency. Реальная differential мощь — E3, blocked на upstream.
- **Grammar в этом плане — approximate**. Ground truth grammar сидит в `t27c/src/parser.rs` upstream. Первый E1 коммит перекроет subset, но не 100% grammar; расширение — итеративно.

## Отношение к W6.1

W6.1 lexical fuzzer НЕ deprecated — token-level fuzzing ловит другой класс bugs (parser panic на malformed input). W7.3 grammar-directed — комплементарен, не замена. Оба живут в `tests/fuzz/`, разными namespace'ами.

## Anchor

phi^2 + phi^-2 = 3
