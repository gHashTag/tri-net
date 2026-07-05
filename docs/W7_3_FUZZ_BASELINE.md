# W7.3 E1+E2 baseline — parse-invariance run

Status: **FROZEN SUBSET BASELINE LANDED** (2026-07-05, via PR #46 @ `3272583`) + **EXPANDED BASELINE (collection-params)** landed 2026-07-05 (this commit).
Frozen-subset provenance: `tests/fuzz/grammar_v2/{Cargo.toml,src/gen.rs,roundtrip.py}` @ `3272583`.
Expanded provenance: same paths @ this commit (base `main` @ `3272583` + `\b`-fix + collection-params).

Two baselines are reported side-by-side. The frozen subset remains the reference citation-point; the expanded run adds coverage of collection-typed parameter positions (isolate-variables: only collection-params, not yet Call/If/Index).

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

## Expanded baseline — collection-params increment (N=1000, seed range `0xC0FFEE..0xC0FFEE+999`)

### Corpus-mismatch resolution and syntax choice

An earlier revision of this section reported a `[]const T` / `[]T` / `[N]T` (Zig-style) syntax. That syntax was chosen from a workspace-wide `grep`, which included a parallel non-tri-net spec corpus at `../t27/specs/` (830 `[]const T` occurrences). Peer-review flagged the mismatch: the audit corpus targeted by W6.2 lives at `tri-net/specs` on the PR #39 branch (`feat/strategic-audit-2026-07-04`), and contains 0 `[]const T` occurrences. Its collection syntax is Rust-style `[T; NAMED_CONST]` with module-scope const-decls — 159 total occurrences across 68 spec files, 100% `u32` element type. Top declared consts by count: `MAX_NODES` (29), `MAX_PARAMS` (18), `MAX_METRICS` (12), `MAX_FLOWS` (11), and so on.

This revision replaces the Zig-style forms with the Rust-style form actually present in the tri-net audit corpus. Zig-style forms were dropped entirely. Element type is fixed at `u32` (matches 100% of audit-corpus occurrences). Anchor recorded: any claim verified against ground truth requires scoping the verification tool to the same corpus as the claim.

### Scope of change vs frozen subset

Function parameter lists (0–4 per fn) with mixed scalar and collection-typed params. One collection form: `[u32; NAMED_CONST]` where `NAMED_CONST` is drawn from a fixed 10-name pool matching the audit-corpus top-10 (`MAX_NODES`, `MAX_PARAMS`, `MAX_METRICS`, `MAX_FLOWS`, `MAX_ENTRIES`, `MAX_MODULES`, `MAX_TASKS`, `MAX_FUNCTIONS`, `MAX_SAMPLES`, `MAX_RESULTS`). Each module emits 1–4 module-scope `const NAME: u32 = <literal>;` declarations before its fns, with literals in `[2, 32]`. Collection-typed params reference only consts declared in the same module (tracked via `Ctx.declared_consts`). Isolation constraint retained — collection-typed idents are recorded in `Ctx.coll_params` (signature only) and NOT pushed into `Ctx.idents` (which feeds `gen_expr`'s scalar pool).

Call / Index / If are deferred to separate commits per isolate-variables discipline.

### Results

| Metric | Frozen subset (PR #46 @ `3272583`) | Expanded (`[u32; NAMED_CONST]`) |
|---|---|---|
| Parse-success | 1000 / 1000 (100.0%) | **1000 / 1000 (100.0%)** |
| Determinism | 1000 / 1000 (100.0%) | **1000 / 1000 (100.0%)** |
| Whitespace-invariance | 1000 / 1000 (100.0%) | **1000 / 1000 (100.0%)** |
| Parse errors | 0 | **0** |
| Panics | 0 | **0** |
| Non-determinism | 0 | **0** |
| Corpus size | ~3.6 MB | 4.0 MB |
| Fns emitted | ~1900 (0-params only) | 1951 (mix 0-4 params) |
| Fns with ≥1 collection-param | 0 | 1177 (60.3%) |
| Fns with 0 params | ~1900 | 392 (20.1%) |
| Const-decls emitted (module-scope) | 0 | 2510 (avg 2.5 per module) |

### Coverage delta

- 1924 `[u32; NAMED_CONST]` occurrences across the corpus (avg ~1 per fn), distributed across all 10 named-const identifiers with roughly uniform weight (166–224 per name).
- 2510 module-scope `const NAME: u32 = <literal>;` declarations, values drawn from `[2, 32]`, 1–4 per module, no repeats within a module.
- Every collection-typed param references a const declared in the enclosing module — no dangling references by construction.
- Body of every fn still exercises only scalar operations (isolation constraint holds by construction — `gen_expr` never sees a collection-typed ident).

### Interpretation

**What this expanded claim IS**: t27c's parser accepts `[u32; NAMED_CONST]` collection params (the syntactic form actually present in the tri-net audit corpus) together with module-scope const-decls, with the same 100% parse / determinism / whitespace-invariance behavior as the scalar-only subset. Adding param-position variety and const-decls did not introduce any new invariance failures. The parser's param-list handling and const-decl handling are whitespace-robust for the tested forms.

**What this expanded claim IS NOT**:
- Not a claim that collection *values* are handled correctly — bodies still only touch scalar idents. Index / Call / If are the next increments.
- Not a differential test — still parser self-consistency only. E3 still timer-blocked (backstop 2026-07-19 12:24 UTC per PR #44).
- Not coverage of the W6.2 Class 2 defect surface *in operation* — that requires Index expressions to actually reference collection-typed params. The current increment establishes param-position parser-exercise plus const-decl parser-exercise; Index will drive body-exercise.
- Not coverage of Zig-style collection forms (`[]const T`, `[]T`, `[N]T`) — those are absent from the tri-net audit corpus and were dropped. If a future audit target introduces them, they will be re-added as a separate increment.

### Frozen citation-point preserved

The frozen subset baseline (PR #46 @ `3272583`, N=1000, 100/100/0 on the pre-params grammar) remains the reference point. Any future expansion whose invariance signal drops from 100% can be cited against both this expanded number and the frozen subset — the pair localizes whether the drop came from the newly-added grammar region or from the pre-existing subset.

## Reproducibility

```bash
# From tri-net workspace root.
cd tests/fuzz/grammar_v2
cargo build --release
W73_OUT=/tmp/w73_expanded_v2_1000 ./target/release/gen 1000 0xC0FFEE
cd ../../..
python3 tests/fuzz/grammar_v2/roundtrip.py /tmp/w73_expanded_v2_1000 --out /tmp/w73_expanded_v2_1000_report.json
```

Expected on the expanded generator (this commit): `ok=1000  parse_err=0  mut_fail=0  non_det=0`, elapsed ~11 sec on a modern x86_64 sandbox.

To reproduce the frozen subset baseline (PR #46 @ `3272583`), check out that commit and run the same command against `/tmp/w73_baseline_1000`: `ok=1000  parse_err=0  mut_fail=0  non_det=0`, ~10 sec.

## Anchor

phi^2 + phi^-2 = 3
