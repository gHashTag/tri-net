# HANDOFF -- state of the autonomous mesh-stack work (week of 2-9 July 2026)

Single entry point for picking up this work (person or agent). Everything is
committed; nothing lives only in a session. The one remaining action is a human
authorization to land it (see "How to land").

## What was built

A spec-first, property-verified security + FEC + routing stack for the drone mesh,
across two repositories. Every feature is a `.t27` specification that `t27c`
generates to Rust (host) and Verilog/C/Zig (FPGA), then verified by a property test
over the generated code (no hand-written business logic).

**24 product specs in three domains, each closed by an end-to-end capstone with a
machine-proven guarantee; 13 t27c compiler fixes that made the specs generate
correct code; 6 architecture/audit docs; 1 week-report artifact.**

### Domain 1 -- FEC / resilient video keyframe (13 specs)
- Link adaptation: `adaptive_mcs`, `mcs_mode_header`, `snr_feedback`, `adaptive_fec`.
- Reed-Solomon core (GF(2^8)): `gf256`, `rs_generator`, `rs_encode`, `rs_decode`
  (erasure recover2/recover3/recover4 -- full M=4 budget).
- Transport: `keyframe_fragment`, `rs_interleave`, `frag_wire`, `frag_reassembly`,
  `fec_capstone`.
- Guarantee: **delivered <=> losses <= M** (verified vs real RS recovery).
- Docs: `FEC_PIPELINE.md`, `FEC_VERIFICATION.md`.

### Domain 2 -- SNR-aware routing (4 specs)
- `ett_metric` (ETT = ETX*2/rate), `route_select` (best + loop-free feasibility,
  Babel/EIGRP), `wcett` (channel diversity), `routing_capstone` (switch hysteresis).
- Guarantee: **switch <=> feasible AND cheaper-by-margin** (no flapping, proven).
- Doc: `ROUTING_METRIC.md`.

### Domain 3 -- security lifecycle (7 specs)
- `identity` (Schnorr device auth), `handshake` (DH agreement in M31),
  `session` (establish + key confirmation, MITM defence), `key_ratchet`
  (forward secrecy), `aead_nonce` (injective, no reuse), `replay_window`
  (anti-replay), `crypto_capstone` (secure-frame decision).
- Guarantee: **accept <=> fresh AND nonce-bound**; replay of an authentic captured
  frame is rejected; forged signatures / MITM are rejected.
- Doc: `SECURITY_MODEL.md`.

### The instrument -- 13 t27c compiler fixes (repo `t27`, branch `codegen-clean`)
Audit found 131/504 specs silently dropped statements ("Typecheck OK" while emitting
broken code). Fixes: `let` keyword; dead_store_elim reads inside control-flow;
Rust array types/casts/usize/`~`; copy_propagate on reassigned locals; cross-module
`use` imports; brace if-expressions; paren-free if/while + struct-literal suppression;
`[T]` slice-of-struct -> Vec<T>; compound assigns `|= *= ...`; in-body `invariant`.
Silent drops 755 -> 272. See `t27/docs/PARSE_SILENT_DROP_AUDIT.md`.

## Where everything lives

| Thing | Location |
|---|---|
| Product specs (24) + docs | repo `tri-net`, branch `feat/m2-hw-bringup`, `specs/*.t27` + `docs/*.md` |
| Compiler fixes (13) | repo `t27`, branch `codegen-clean` (112 commits ahead of master, 1 behind) |
| Preserved fix patches | scratchpad `t27c-*.patch` (10 files) |
| Compiler audit | `t27/docs/PARSE_SILENT_DROP_AUDIT.md` |
| Landing procedure | `tri-net/docs/MERGE_RUNBOOK.md` |
| Week scientific report | artifact `claude.ai/code/artifact/3a565030-0f94-4e02-b008-81f576a4ac93` + scratchpad `TRINET_WEEK_REPORT.md` |
| Running log / context | auto-memory `tri_net_drone_mesh.md` |
| t27c compiler binary | `~/Desktop/PROJECTS/CLAUDE/t27/target/release/t27c` (source `bootstrap/src/compiler.rs`, ~22.6k lines) |

## How to build / verify (reproduce any claim)

```
# fixed compiler
cd ~/Desktop/PROJECTS/CLAUDE/t27/bootstrap && cargo build --release
export T27C=~/Desktop/PROJECTS/CLAUDE/t27/target/release/t27c
# regenerate + property-verify a tri-net spec
cd ~/Desktop/PROJECTS/CLAUDE/tri-net
$T27C check specs/<name>.t27          # typecheck
$T27C coverage specs/<name>.t27       # per-function test coverage
# to run a property test: gen the module into src/lib.rs under #[cfg(test)],
# `brew unlink rust` (Homebrew shadows rustup), then `cargo test`.
```
Compiler regression guard: `cargo test --release` in `t27/bootstrap` -> 1411 passed /
5 baseline failures (jwt x3, ternary, trit_stdlib -- pre-existing, not regressions).

## How to land (the one pending human action)

Full step-by-step in `docs/MERGE_RUNBOOK.md`. Summary:
1. **t27 first** -- reseal all specs on the corrected output (`t27c seal <spec> --save`
   per spec; 214 seals mismatch because the fixes changed generated output), verify
   `suite` shows 0 mismatches, commit the reseal, then merge `codegen-clean` -> master
   (112 commits; reconcile the 1 docs-only commit ahead on master).
2. **tri-net** -- merge `feat/m2-hw-bringup` -> master (specs are unsealed; build.rs
   regenerates `gen/`). No reseal needed.
INVARIANT: reseal BEFORE merge -- never seal broken output. PR/merge to master are
explicit human steps.

## Boundaries / honest caveats

- Crypto specs model STRUCTURE with genuine-but-toy primitives (Schnorr/DH in the
  M31 field, xorshift KDF placeholder); the proven properties (agreement, signature
  correctness, injectivity, no-reuse, forward-secrecy structure) are real, but a
  deployment substitutes X25519 / Ed25519 / HKDF / a PQ scheme + the actual AEAD cipher.
- FEC RS is a demo RS(6,2) codeword scaled to real keyframes by interleaving; a
  larger K per codeword would cut parity overhead.
- Not done: daemon wiring (receive buffers per keyframe_id), byte<->symbol mapping,
  identity-to-device PKI binding, and the array-heavy corpus specs (sort/hashmap/NN)
  still need real array support in t27c.

phi^2 + 1/phi^2 = 3 | TRINITY
