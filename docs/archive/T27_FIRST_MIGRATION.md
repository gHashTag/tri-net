# T27-first migration — wire.rs (partial flip)

Anchor: `phi^2 + phi^-2 = 3`.

## Why

Prior state: `specs/wire.t27` and `src/wire.rs` were maintained in parallel. The spec was proven correct via `vvp` but was not the source of truth for the daemon — Rust was written by hand and drifted freely.

New state: `.t27` spec is SSOT. `t27c gen-rust` emits `gen/rust/wire.rs` deterministically. Hand-written Rust in `src/wire.rs` re-exports the generated symbols and only adds ergonomic wrappers (`Header` struct, `FrameKind` enum, `to_bytes` / `parse`) on top. Any drift between spec and daemon is now a build-time or test-time failure, not a review-time oversight.

## What flipped

Currently auto-generated (from `specs/wire.t27` via `t27c gen-rust`):

| Symbol | Kind |
|---|---|
| `VERSION` | `const u8 = 1` |
| `KIND_HELLO` | `const u8 = 0` |
| `KIND_DATA` | `const u8 = 1` |
| `HEADER_LEN` | `const usize = 11` |
| `frame_kind_valid(k: u8) -> bool` | pure predicate |
| `header_byte(kind, src, dst, ttl, idx) -> u8` | pure indexed layout |
| `parse_accepts(b0: u8, b1: u8) -> bool` | pure predicate |

Additionally auto-generated after t27#1320 (ExprCast Rust emitter):

- `be_byte(w: u32, i: usize) -> u8` — emits real `((w >> 24) & 255) as u8` cast chain.
- `u32_be(b0..b3: u8) -> u32` — emits real `(b0 as u32) << 24 | ...` recombination.

Still hand-written in `src/wire.rs`:

- `Header` struct, `FrameKind` enum, `Header::to_bytes`, `Header::parse`.
- These delegate ALL constants, predicates, AND byte-layout to the auto-gen module — they do not re-declare `VERSION`, `HEADER_LEN`, or any per-byte computation.

## Bootstrap history — ExprCast gap (resolved on all four backends)

The initial partial flip (PR #33 first commit `a6bb0b0`) shipped hand-written `be_byte` / `u32_be` stubs because `t27c-0.1.0` had no `ExprCast` lowering in the Rust, Zig, or C text emitters. Only `gen-verilog` implemented the cast. On the other three backends the AST node fell through the default arm and produced `"()"` — a type error in Rust, a parse error in Zig, and an honest `/* unsupported: ExprCast */` in C.

Initial triage guessed the bug was in bit-shift parsing, because the first `wire.t27` line that failed was `((w >> 24) & 255) as u8`. Isolation showed the shift is a red herring — the cast is what breaks. Repro table and root-cause pointer live in the upstream issue.

**Status**: fully resolved on all four backends.

- Rust arm — [gHashTag/t27#1320](https://github.com/gHashTag/t27/pull/1320) (closes [t27#1314](https://github.com/gHashTag/t27/issues/1314)); lives at `bootstrap/src/compiler.rs:8172`, emits `({operand} as {target})`.
- Zig arm — [gHashTag/t27#1337](https://github.com/gHashTag/t27/pull/1337) (closes [t27#1333](https://github.com/gHashTag/t27/issues/1333)); emits `@as(<T>, @intCast(<operand>))` — narrows and widens, stronger than the `@as`-only suggestion.
- C arm — [gHashTag/t27#1337](https://github.com/gHashTag/t27/pull/1337); emits `((<uintN_t>)(<operand>))` via `Self::type_to_c`.
- Verilog arm — already lowered ExprCast pre-#1320.

`tri-net` now consumes three text backends (`gen-rust`, `gen`, `gen-c`) all under drift-guard.

## Build story

- `gen/rust/wire.rs` is committed. Contributors do not need `t27c` installed to build tri-net.
- `build.rs` will optionally invoke `t27c gen-rust` when `T27C_REGENERATE=1` is set and `t27c` is on `$PATH` (or `T27C=/path/to/t27c`). It prints a warning if the invocation fails and does not fail the build — CI without `t27c` still passes.
- `build.rs` deliberately does not overwrite `gen/rust/wire.rs` automatically — the CI drift-guard (`.github/workflows/spec-drift-guard.yml`) rebuilds t27c from t27 master and diffs the regenerated output against every committed file under `gen/<target>/wire.*` on every PR, so drift is caught at PR time rather than silently masked by a per-machine local regeneration. The guard covers three backends today: `gen/rust/wire.rs` (via `t27c gen-rust`), `gen/zig/wire.zig` (via `t27c gen`), and `gen/c/wire.c` (via `t27c gen-c`). Contributors who want a local check can set `T27C=/path/to/t27c T27C_REGENERATE=1 cargo build` and compare stdout manually.

## Test story

`src/wire.rs` gains two guardrail tests:

- `t27_gen_constants_match_hand_written` — pins auto-gen constant values.
- `t27_gen_predicates_match_semantics` — exercises `frame_kind_valid` and `parse_accepts` on representative inputs.

If someone edits `specs/wire.t27` and reruns `t27c gen-rust`, and the constants shift, these tests fail loudly. Existing `header_roundtrips` and `bad_version_rejected` continue to cover end-to-end serialization.

Green as of this commit:

- `cargo test --lib` — 101/0.
- `cargo test --test m2_routing_pure_logic` — 25/0.
- `cargo fmt --all -- --check` — clean.

## Next flips (future loops)

- ~~Full flip once `ExprCast` lowering lands~~ — done (t27#1320 merged into master `c4dc8ee`; tri-net#33 promoted `gen/rust/wire.rs` to raw t27c output).
- `src/discovery.rs` HELLO framing → `specs/discovery.t27` counter/timer skeleton.
- `src/daemon.rs` framing FSM → `specs/daemon.t27` for the state transitions.
- ETX and GF16 stay blocked on t27#1258 (array/RAM support in the bootstrap parser).

`crypto.rs` (X25519, ChaCha20-Poly1305) and `modem.rs` RX DSP (float pipeline) remain out of scope by design — T27 is an integer hardware-datapath language.

## Regeneration recipe

```
# On a machine with t27c on $PATH (after t27#1320 merges into t27c):
cd tri-net
t27c gen-rust specs/wire.t27 > gen/rust/wire.rs.new

# Diff against the committed output:
diff gen/rust/wire.rs gen/rust/wire.rs.new

# Promote (see the rule below — regen overwrites the whole file by design):
mv gen/rust/wire.rs.new gen/rust/wire.rs
cargo test --lib && cargo test --test m2_routing_pure_logic
```

Pre-validated 2026-07-04 against the post-t27#1320 t27c: regen overwrites the
whole file (~49 lines removed / ~40 added vs the hand-touched committed
version), NOT just the stub band. Tests stay 101/0 + 25/0. The bigger diff is
expected and correct: it removes the now-obsolete `ExprCast` banner and the
hand-stubs, and normalises cosmetic rendering to raw t27c output.

## Rule: `gen/` is untouchable raw output

`gen/rust/*` (and `gen/<lang>/*` generally) is the deterministic output of
`t27c`. It is never hand-edited — no banners, no comments, no cosmetic cleanups,
no stub bands. Anything explanatory (migration notes, caveats, status banners)
belongs in the **consumer** (`src/wire.rs` module doc) or in this migration
doc, never in the generated file.

If `t27c` emits something wrong, the fix is upstream in `t27c` itself
(e.g. t27#1320 for `ExprCast`), never a patch to `gen/`. Once the upstream fix
lands, regenerate and the whole `gen/` file becomes canonical raw output.

Diff-shape lesson from this PR: a "stub-only" regen diff is only possible when
`gen/` was never hand-touched. The moment any hand-edit (even a documentation
banner) lands in `gen/`, every later regen rewrites it — which is correct
behaviour, not a surprise. Keep `gen/` pure.
