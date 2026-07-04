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

Still hand-written in `src/wire.rs`:

- `Header` struct, `FrameKind` enum, `Header::to_bytes`, `Header::parse`.
- These now delegate all constants and layout decisions to the auto-gen module — they do not re-declare `VERSION`, `HEADER_LEN`, or the byte layout.

## Bootstrap limitation (why not full flip yet)

`t27c-0.1.0` bootstrap has a missing lowering for `ExprCast` (the `expr as Type` form) in the Rust, Zig, and C text emitters. Only `gen-verilog` implements the cast. On the other three backends the AST node falls through the default arm of `expr_to_rust` / `expr_to_zig` / the C printer and produces the unit value `"()"`, which then miscompiles: `return ();` in a `-> u8` Rust function is a type error, `return ;` in Zig is a parse error, and `gen-c` prints an honest `/* unsupported: ExprCast */`.

Initial triage in this session guessed the bug was in bit-shift parsing, because the first `wire.t27` line that failed was `((w >> 24) & 255) as u8`. Isolation showed the shift is a red herring — the cast is what breaks. Repro table and root-cause pointer live in the upstream issue: `gHashTag/t27#1314`.

Because `be_byte` and `u32_be` both need `as u8` / `as u32` casts, neither can come from the compiler in its current form. Workaround in this PR: `gen/rust/wire.rs` carries hand-written `be_byte` / `u32_be` stubs beneath a banner that documents the limitation. When `t27c` gains an `ExprCast` arm in the Rust emitter, delete the stubs and let `gen-rust` emit them.

Tracked upstream: [gHashTag/t27#1314](https://github.com/gHashTag/t27/issues/1314).

## Build story

- `gen/rust/wire.rs` is committed. Contributors do not need `t27c` installed to build tri-net.
- `build.rs` will optionally invoke `t27c gen-rust` when `T27C_REGENERATE=1` is set and `t27c` is on `$PATH` (or `T27C=/path/to/t27c`). It prints a warning if the invocation fails and does not fail the build — CI without `t27c` still passes.
- `build.rs` intentionally does not overwrite `gen/rust/wire.rs` today, because that would clobber the hand-written stubs. Once the bit-shift bug is fixed, switch it to a direct overwrite.

## Test story

`src/wire.rs` gains two guardrail tests:

- `t27_gen_constants_match_hand_written` — pins auto-gen constant values.
- `t27_gen_predicates_match_semantics` — exercises `frame_kind_valid` and `parse_accepts` on representative inputs.

If someone edits `specs/wire.t27` and reruns `t27c gen-rust`, and the constants shift, these tests fail loudly. Existing `header_roundtrips` and `bad_version_rejected` continue to cover end-to-end serialization.

Green as of this commit:

- `cargo test --lib` — 101/0.
- `cargo test --test m2_routing_pure_logic` — 25/0.
- `cargo fmt --all -- --check` — clean.

## Next flips (out of scope for this PR)

- Full flip once t27c bit-shift is fixed — `be_byte` / `u32_be` become auto-gen too.
- `src/discovery.rs` HELLO framing → `specs/discovery.t27` counter/timer skeleton.
- `src/daemon.rs` framing FSM → `specs/daemon.t27` for the state transitions.
- ETX and GF16 stay blocked on t27#1258 (array/RAM support in the bootstrap parser).

`crypto.rs` (X25519, ChaCha20-Poly1305) and `modem.rs` RX DSP (float pipeline) remain out of scope by design — T27 is an integer hardware-datapath language.

## Regeneration recipe

```
# On a machine with t27c on $PATH:
cd tri-net
t27c gen-rust specs/wire.t27 > gen/rust/wire.rs.new

# Diff against committed output:
diff gen/rust/wire.rs gen/rust/wire.rs.new

# If the diff is only inside the auto-gen band (above the "Hand-written stubs"
# banner), promote it:
mv gen/rust/wire.rs.new gen/rust/wire.rs
cargo test --lib
```

Never edit `gen/rust/wire.rs` by hand outside the stubs band. The banner in the file makes this explicit.
