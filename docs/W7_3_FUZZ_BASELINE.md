# W7.3 E1+E2 baseline — parse-invariance run

Status: **BASELINE LANDED** (2026-07-05).
Branch: `w7/testing/fuzz-baseline` (PR #46).
Provenance: `tests/fuzz/grammar_v2/{Cargo.toml,src/gen.rs,roundtrip.py}` @ this commit.

## Setup

- **Generator**: `tests/fuzz/grammar_v2/src/gen.rs` (E1, W7.3-E1 commit + `max_stmts_per_fn` reconciliation).
- **Harness**: `tests/fuzz/grammar_v2/roundtrip.py` (E2).
- **t27c**: `/home/user/workspace/t27/target/release/t27c` (from t27 workspace, master post-#1348 era).
- **Seed**: `0xC0FFEE` base + per-module offset `+i`.
- **Corpus**: N=1000 modules generated to `/tmp/w73_baseline_1000/*.t27` (spec bodies not committed — reproducible from seed).

## Invariants tested

For each generated module, the harness runs three passes:

1. **Parse-success**: `t27c parse <path>` returns exit code 0 (no error, no panic).
2. **Determinism**: parsing the same input twice yields identical AST (after normalization).
3. **Whitespace-invariance**: three non-semantic mutations are applied and re-parsed:
   - `extra_spaces` — double every leading-indent space run.
   - `extra_newlines` — add blank line after every `}\n`.
   - `trailing_ws` — add trailing spaces to every non-empty line.
   Each mutated variant must parse to the same normalized AST as the original.

## Normalization

The harness strips `line: N,` fields from `t27c parse`'s Debug-formatted AST before comparison, because these are source-position metadata derived from layout, not structural content. Extra newlines shift them without changing meaning. Any remaining structural change after stripping is treated as a real invariance violation.

## Results (N=1000, seed range `0xC0FFEE..0xC0FFEE+999`)

| Metric | Value |
|---|---|
| Parse-success | **1000 / 1000 (100.0%)** |
| Determinism | **1000 / 1000 (100.0%)** |
| Whitespace-invariance | **1000 / 1000 (100.0%)** |
| Parse errors | 0 |
| Panics | 0 |
| Non-determinism | 0 |
| Elapsed | 9.9 sec (3000+ subprocess calls: baseline + determinism + 3 mutations per input) |

All three success criteria from `W7_3_FUZZ_BASELINE_PLAN.md` §Success-criterion met:

- ✓ 100% grammar-valid generations parse cleanly (target: 100%).
- ✓ 100% whitespace-invariant (target: ≥95%).
- ✓ 0 panics in t27c parser.

## Interpretation

**What this claim IS**: for the grammar subset E1 currently covers (Module, FnDecl with zero params, Let / Return stmts, Expr = Literal / Ident / BinOp / Cast / Cmp, six primitive types), t27c parses cleanly, deterministically, and is invariant to non-semantic whitespace changes across 1000 random seeds.

**What this claim IS NOT**:
- Not a differential test — this is parser self-consistency only. Real backend-differential (E3) needs the upstream Stmt::Let fix from [t27#1401](https://github.com/gHashTag/t27/issues/1401) to land first.
- Not full-grammar coverage. Missing from E1 today: function parameters, `Call`, `Index`, `If` statements, `UseDecl`, `ConstDecl`. See "Tracked TODOs before E3" below.
- Not a full round-trip via pretty-printer. t27c doesn't expose a public pretty-printer in the current version. Parse-invariance is a strict subset of the intended round-trip and still catches parser non-determinism, whitespace-sensitivity, and panics. Full round-trip via pretty-printer is a TODO once t27c exposes one.

## Discipline honesty

One methodological wrinkle was caught during the smoke run (N=20 before N=1000):

The first version of `normalize_ast` collapsed whitespace but left `line: N` fields intact. This produced a 75% failure rate on the `extra_newlines` mutation, because adding blank lines shifts line numbers for every subsequent AST node. The failure was NOT a parser bug — it was over-strict normalization treating source-position metadata as structural content. Fix: strip `line: N,` fields before comparison. After the fix, N=20 smoke passed 100%, and the N=1000 full run followed. This wrinkle is documented so the normalization choice is auditable and the "100% invariance" claim is understood as "invariant modulo source-position metadata," not "byte-for-byte identical output."

## Tracked TODOs before E3 unblock

The E1 grammar subset does not exercise function parameters. The W6.2 audit found the `Vec<>` defect (E0107, Class 2) lives in param-position. E3's differential power depends on exercising the grammar regions where bugs hide. Therefore:

- **Before E3**: extend E1 to generate function parameters (including collection params like `Vec<u8>`) and `Call` / `Index` expressions.
- **Backstop timer for E3**: 2026-07-19 12:24 UTC (14 days from t27#1401 publication), or terminal event on t27#1401 (won't-fix / closing PR / explicit reject), whichever comes first. See `W7_COLLAB_OPTIONS.md` §external-dep-timer rule.

Between now and that deadline, E1 grammar expansion is the primary open workstream on this branch.

## Reproducibility

```bash
# From tri-net workspace root.
cd tests/fuzz/grammar_v2
cargo build --release
W73_OUT=/tmp/w73_baseline_1000 ./target/release/gen 1000 0xC0FFEE
cd ../../..
python3 tests/fuzz/grammar_v2/roundtrip.py /tmp/w73_baseline_1000 --out /tmp/w73_baseline_1000_report.json
```

Expected: `ok=1000  parse_err=0  mut_fail=0  non_det=0`, elapsed <15 sec on a modern x86_64 sandbox.

## Anchor

phi^2 + phi^-2 = 3
