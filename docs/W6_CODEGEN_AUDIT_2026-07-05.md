# t27c Codegen Audit — 2026-07-05

> phi^2 + phi^-2 = 3

## Executive summary

t27c generates textually deterministic output — 68 of 68 modules are
byte-identical on repeated runs (verified by
[`ci: spec-drift-guard`](https://github.com/gHashTag/tri-net/pull/38)).
However, this audit finds that the generated code contains extensive
downstream-compilability defects that are visible to standard compilers
in all three target backends.

**Tri-backend per-file compile matrix** (68 modules from
`feat/strategic-audit-2026-07-04`, commit
[`bf50ad64`](https://github.com/gHashTag/tri-net/pull/39)):

| backend | toolchain | OK | FAIL | dominant defect |
|---|---|---:|---:|---|
| Rust | rustc 1.93.1, `--emit=metadata` | 19 / 68 (28%) | 49 / 68 | undeclared identifier in function bodies (E0425 = 2609 sites) |
| C | gcc, `-c -std=c11 -Wall -Wextra` | 2 / 68 (2.9%) | 66 / 68 | undeclared identifier (1957) + `assert(cond, msg)` 2-arg misuse (867) |
| Zig | (static verdict, methodology below) | 0 / 68 (0%) | 68 / 68 | missing `types.zig` (64 importers) + `@compileError` stubs (4) |

**Cross-backend compilation intersection: ∅ (empty).**
Rust-OK ∩ C-OK ∩ Zig-OK = {} — no module compiles in all three backends.
The single module that compiles in both Rust and C (`wire`) fails in Zig
because it imports the missing `types.zig`.

**Consequences for W6.2 plan:**

- **W6.2-B (runtime differential testing) is structurally infeasible** as
  originally scoped. A tri-backend runtime diff requires at minimum one
  module that compiles across all three backends; the intersection is
  empty, so there is no common runtime surface to compare. This is itself
  a finding, not an execution failure.

## Methodology

### Data source

All 68 modules used in this audit come from the `gen/` tree at commit
`bf50ad64` on branch `feat/strategic-audit-2026-07-04` (open in
[PR #39](https://github.com/gHashTag/tri-net/pull/39)). That branch
holds the SSOT-conformant 68/68 generation output. The `main` branch at
`dc1bebb` currently carries only the `wire` module in `gen/` — the
remaining 67 modules are pending land through their own review path.

This audit reads from the strategic-audit tree and does not modify or
duplicate any generated file on this branch. Reproducibility scripts
in `scripts/audit/` operate on whichever branch is currently checked
out; the numbers below are reproducible by running them against
`feat/strategic-audit-2026-07-04`.

### Rust sweep — `scripts/audit/rust_compile_sweep.sh`

Each `gen/rust/*.rs` file is a self-contained crate root: only
top-level `pub const` and `pub fn` definitions, no `use` of sibling
modules, no `#[cfg(test)]` blocks, no `#[test]` functions. Because
there are no cross-file dependencies, each file can be type-checked
independently with `rustc --edition 2021 --emit=metadata --crate-type lib`.
This is the same analysis pass that `cargo check` performs.

### C sweep — `scripts/audit/c_compile_sweep.sh`

Each `gen/c/*.c` file is compiled with `cc -c -std=c11 -Wall -Wextra
-Wno-unused`. Unlike Rust, `cc` compiles every function in a translation
unit whether or not the function is used; the t27c-emitted `void test_*`
functions are therefore analyzed too.

### Zig verdict — `scripts/audit/zig_static_check.sh`

The Zig compiler was not required to reach the compile verdict for this
audit. The verdict is derived from two version-invariant structural facts,
each verifiable by filesystem inspection and `grep`:

1. `gen/zig/types.zig` does not exist in the tree, and `git log --all
   -- '**/types.zig'` shows the file has never existed in any commit
   on any branch.
2. Of the 68 `gen/zig/*.zig` files, 64 contain `@import("types.zig")`
   at module scope. Under any Zig compilation mode
   (`build-obj`, `test`, `test --test-no-exec`), an unresolved
   module-scope `@import` is a hard failure. Therefore these 64 files
   cannot compile — this holds independently of Zig version and mode.

The remaining 4 files (`adaptive_retry`, `link_quality_monitor`,
`m3_multihop`, `multipath_router`) do not import `types.zig`. Each
contains 3–6 `@compileError("not yet implemented")` calls in stub
function bodies, which is sufficient to prevent compilation under
`zig test`; these files may additionally exhibit test-block defects
not individually characterized here. Under a lenient `zig build-obj`,
Zig's lazy analysis may
skip `@compileError` in an unreferenced private function; the 4-file
result therefore depends on function reachability and mode. We did
not empirically test `zig build-obj` lenient mode in this audit; the
reachability claim is grounded in Zig's documented lazy-analysis
semantics, not in measurement.

**Precise Zig claims used in this audit:**

- 64 / 68 fail under any Zig mode — hard, structural.
- 4 / 68 fail under `zig test` and `zig test --test-no-exec` — soft,
  reachability-dependent under lenient modes.
- 0 / 68 pass under `zig test --test-no-exec` — preliminary
  cross-environment evidence, zig 0.15.2, independent-environment
  run on a separate host; sandbox reproduction pending toolchain
  availability. The 64-file hard-fail claim stands on filesystem and
  git-history inspection alone, independent of this empirical run.

### Methodology asymmetry (important disclosure)

The three sweeps do not measure exactly the same scope of code:

- **Rust sweep measures library code only.** The `gen/rust` files
  contain no `#[test]` functions, so `rustc --emit=metadata` analyzes
  only `pub fn` bodies and top-level items.
- **C sweep measures library plus test-template code.** `cc -c` compiles
  every function in each `.c` file, including the `void test_*()`
  functions that t27c emits. A substantial fraction of the 66 / 68
  C failures — including the 867 instances of the `assert(cond, msg)`
  2-argument misuse and many `undeclared identifier` errors — originate
  in these test blocks.
- **Zig verdict measures under `zig test` semantics** (all reachable
  code + test blocks), matching the C sweep's scope more closely than
  the Rust sweep's.

The tri-backend headline (**empty compile intersection, 0 / 68 modules
cross-compilable**) is not affected by this asymmetry, because it turns
on Zig's 0 / 68 which is driven by the missing-`types.zig` structural
defect at module scope, not by test-template content.

The per-backend gradient (Rust 28% > C 2.9% > Zig 0%), however, is
partly attributable to methodology. A future symmetric sweep — either
extending Rust to include `#[test]`-instrumented test templates, or
narrowing C and Zig to library-only compilation — would give a
methodology-controlled comparison. Until that is done, per-backend
percentages should be read with this asymmetry in mind. The finding
of interest for this audit is not the gradient but the empty
intersection.

## Defect taxonomy

Eight distinct codegen defect classes are identified. Classes 1–5
are Rust-visible; classes 6–7 are C-visible; class 8 is Zig-visible.
Class 1 recurs in all three backends and is the largest single-class
source of failures overall.

### 1. Undeclared identifier in function bodies

**Rust:** E0425 = 2609 instances across 49 files.
**C:** `X undeclared (first use in this function)` = 1957 instances
across many files (including the "did you mean" variant, 115 more).
**Zig:** present in test blocks, e.g. `byte_utils.zig` writes
`bit = get_bit(0x01, 0);` where `bit` is never declared with `var`.

t27c emits function bodies (and, in C and Zig, test bodies) that
reference identifiers not bound in the enclosing scope. Example from
`gen/rust/access_control.rs:67`:

```rust
if !(role_meets_minimum(role, min_role)) {
```

`min_role` is not a parameter of the enclosing function and not
introduced as a `let` binding above. The same access_control example
recurs in `gen/c/access_control.c` (undeclared `min_role`, `node_id`,
`role`, `token`).

This defect is the largest single class in both Rust (93% of coded
errors) and C (~70% of errors). It is backend-independent — the same
generator bug surfaces in every language.

### 2. `Vec<>` with empty element type (Rust only)

**Rust:** E0107 = 159 instances across 22 files.

t27c emits `Vec<>` where a `Vec<T>` is required. Rust's type parser
requires a concrete element type in generic positions, so `Vec<>` is
a hard error. C and Zig express collection parameters differently
(pointers with length; slices), so this defect does not surface in
those backends.

### 3. Cross-width comparison without cast (Rust only)

**Rust:** E0308 = 28 instances.

Example, `gen/rust/crc16.rs:9`:

```rust
if (((crc >> 15) & 1) != (bit & 1)) {
```

`(crc >> 15) & 1` has type `u16` (because `crc: u16`), and `(bit & 1)`
has type `u8` (because `bit: u8`). Rust does not implicitly convert
between integer widths; the `!=` is rejected. C promotes both sides
to `int` via the usual arithmetic conversions and silently accepts —
so the C output for the same module produces a program that compiles
(though this program is still rejected by other errors in the same
file). Zig also requires explicit casts across widths, so this defect
would surface in Zig too if the file reached body analysis; the
missing-`types.zig` import blocks it earlier.

### 4. Integer literal out of range (Rust only)

**Rust:** 3 bare `error: literal out of range for u8`.

Example, `gen/etx.rs:39`:

```rust
return (fp_mul(alpha, sample) + fp_mul((256 - alpha), est));
```

`alpha: u8`. `256` does not fit in `u8`. Rust's default
`deny(overflowing_literals)` rejects this. C evaluates `256 - alpha`
in `int` arithmetic and truncates on assignment (behavior which may
or may not match the generator's intent — this is a semantically
loaded silent-accept).

### 5. Reserved-word collision (Rust only, 1 module)

**Rust:** 2 bare errors — `expected identifier, found keyword type`
and `expected expression, found keyword type` — both in
`gen/rust/traffic_animator.rs`.

t27c emits `type` as an identifier in this module. `type` is a Rust
keyword and cannot be used as an identifier. C accepts `type` as an
identifier; Zig treats `type` as a metatype-keyword and would reject
it.

### 6. `assert(cond, msg)` two-argument misuse (C only)

**C:** 867 instances.

t27c emits `assert(cond, "message")` for C. This matches the shape
of Rust's `assert!(cond, msg)` and Zig's `std.debug.assert(cond)` /
`std.testing.expect`, but C's `<assert.h>` `assert` is a
single-argument macro. GCC reports `macro 'assert' passed 2
arguments, but takes just 1`.

This is the single most upstream-actionable defect in the audit:
it is a localized emission-rule choice (route C's assertion path
through a macro that accepts a message, or drop the message argument
for C), and fixing it removes an entire defect class from the C
column.

### 7. Missing dependency file `types.zig` (Zig only)

**Zig:** 64 files reference a file that does not exist.

Every gen/zig file that imports types imports it as
`@import("types.zig")`, but t27c has never generated a `types.zig`
file — the file is not in the current tree and `git log --all --
'**/types.zig'` returns no history. Under any Zig compilation mode,
an unresolved module-scope `@import` is a hard failure.

This is a pure codegen-plumbing defect: t27c emits references to a
dependency that its own backend never produces. The fix is either
to generate a suitable `types.zig` (containing type aliases and any
shared decls the imports use) or to inline the type references at
each use site.

### 8. Stub-lowering policy divergence (all three backends)

Twenty-four spec functions are stub-implemented across three backends
with different failure modes:

- **Zig:** `@compileError("not yet implemented")` — compile-time
  refusal.
- **Rust:** `unimplemented!()` — runtime panic (compiles fine).
- **C:** `/* TODO: implement */` with no return statement — undefined
  behavior on fall-off from a non-void function.

The 24 stub sites are distributed across eight modules:
`lite_crypto` (1), `m3_multihop` (6), `pattern_predictor` (1),
`olsr_routing` (2), `production_deployment` (1),
`link_quality_monitor` (5), `adaptive_retry` (5),
`multipath_router` (3).

This is not a codegen bug in the emitting sense — t27c is
deliberately lowering "not yet implemented" spec functions differently
per backend. But the three chosen lowering policies produce three
different failure characteristics (compile-time / runtime-explicit /
runtime-silent). A choice is worth making about whether the three
backends should have a unified stub policy.

## Section 4.5 reconciliation

The current paper §4.5 asserts "68 / 68 byte-identical generation."
This statement is empirically true as a property of t27c's output
stream: rerunning t27c on the 68 specs produces byte-identical
output, and the `spec-drift-guard` CI check enforces this on every PR
touching `specs/`.

However, "byte-identical generation" is a property of the generator's
determinism, not of the correctness of the generated code as measured
by any downstream compiler. Read alone, the 68 / 68 figure invites
the inference "the generator works" — an inference this audit shows
is not supported when the code is passed to `rustc`, `cc`, or `zig`.

**Recommended §4.5 language (companion phrasing, not replacement):**

> t27c emits output for 68 of 68 tri-net protocol modules across three
> text backends (Rust, C, Zig) with byte-identical determinism enforced
> by `spec-drift-guard` CI. The generated output stream is reproducible;
> however, downstream compilability is a separate property. As documented
> in the codegen-quality audit ([this document]), 0 of 68 modules compile
> across all three backends simultaneously — a finding that is
> independent of the audit's per-backend methodology. Per-backend compile
> rates and the methodology governing their cross-backend comparability
> are reported in the audit. Section 4.5's byte-identity claim is a
> statement about output-stream determinism only.

Sections that build downstream inference on §4.5 (specifically any
runtime differential or cross-backend equivalence claim) require
either a corrected scope (limited to `wire` in Rust+C, the only
non-trivial cross-backend-OK subset) or an explicit deferral until
the codegen defects are addressed.

## Anchor-bias record — this audit's own errata

This audit went through three iterations before reaching bedrock.
The audit records them because the pattern is instructive for future
codegen investigations:

1. **First anchor: `grep 'Vec<>'`.** Initial static-token scan
   reported 132 `Vec<>` instances across 22 files, and the framing
   inferred from that scan was "Rust codegen has a `Vec<>` defect."
   This inference was wrong.
2. **Second anchor: compile ground-truth on Rust.** Running
   `rustc --emit=metadata` on the 68 files revealed 49 failing
   files, not 22. Of those, only 22 mentioned `Vec<>` in their
   errors; the other 27 failed for other reasons. `Vec<>` (E0107 =
   159) is 5.6% of Rust errors, not the dominant defect. Undeclared
   identifiers (E0425 = 2609, 93% of errors) are the dominant defect.
3. **Third anchor: differential narrative "C silently accepts what
   Rust rejects."** This inference was partially correct only for
   the 3 modules with type-coercion / literal-overflow defects
   (`crc16`, `etx`), and was flatly wrong for the 66 / 68 C failures
   that arise from the same undeclared-identifier codegen bug that
   affects Rust. Cross-backend runnability of otherwise-broken code
   is the exception in this corpus, not the rule.

Methodological consequence: **static-token grep is not a reliable
substitute for compiler verdicts.** Every quantitative claim in this
audit is grounded in either compiler output (Rust, C) or in
version-invariant filesystem / git-history inspection (Zig), and
each is reproducible via a script under `scripts/audit/`.

## Reproducibility

Toolchain versions used to produce the numbers in this document:

- rustc 1.93.1 (01f6ddf75 2026-02-11)
- gcc (as system `cc`)
- zig 0.15.2 (cross-environment empirical confirmation only; audit
  Zig verdict does not require an installed Zig)

Data source: `gen/` tree at commit `bf50ad64` on
`feat/strategic-audit-2026-07-04`.

To reproduce:

```
git checkout feat/strategic-audit-2026-07-04
bash scripts/audit/rust_compile_sweep.sh   # Rust: 19 OK / 49 FAIL / 68
bash scripts/audit/c_compile_sweep.sh      # C: 2 OK / 66 FAIL / 68
bash scripts/audit/zig_static_check.sh     # Zig: static verdict
```

The sweep scripts print totals, per-file OK/FAIL, error-code
histograms, and top error-message families to stdout. They exit
non-zero if the toolchain is not available.

## What this audit does not do

- It does not modify `t27c` source. Upstream fixes are out of scope
  for this document; the audit's role is to establish and cite the
  defects, not to remove them.
- It does not run any generated code. W6.2-B (runtime differential)
  is cancelled by the empty compile intersection.
- It does not re-run the Rust or C sweep on `main`; on `main`
  currently only `wire` exists in `gen/`. The numbers above apply
  to `feat/strategic-audit-2026-07-04` where the full 68/68 tree
  is present.
- It does not judge whether t27c should exist, or whether
  tri-backend generation is the right approach for tri-net.
  The audit reports the state of the current output, not the
  desirability of the design.

## References

- [PR #39 — strategic audit branch](https://github.com/gHashTag/tri-net/pull/39)
  hosts the full 68/68 `gen/` tree used as data source.
- [PR #38 — spec-drift-guard extension](https://github.com/gHashTag/tri-net/pull/38)
  establishes the byte-identity CI check that motivates §4.5's
  "68 / 68 byte-identical" claim.
- [PR #41 — W6.1 structural fuzz](https://github.com/gHashTag/tri-net/pull/41)
  establishes cross-backend spec-acceptance agreement (a separate
  claim from cross-backend compile agreement, and not contradicted
  by this audit).

> phi^2 + phi^-2 = 3
