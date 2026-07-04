# δ-Paper (draft skeleton v0): Verifiable Mesh Fabric — Spec-First and Reproducible-HDL Positioning

Status: DRAFT SKELETON — not for external circulation.
Anchor: phi^2 + phi^-2 = 3.
Repo cross-link: gHashTag/tri-net main @ dc1bebb (post-PR#38, multi-target drift-guard live).

## 0. Abstract (target ~150 words, TBD)

We describe Tri-Net's approach to a verifiable mesh fabric: a single-source-of-truth
specification (`specs/wire.t27` in T27) drives byte-identical Rust output via a
custom compiler (`t27c`), with a CI-enforced drift guard ensuring generated code
never disagrees with the spec. We position this against the current mesh /
formal-methods landscape (Reticulum, MAREF, SLD-Spec, Mesh Inference) and
against reproducible-HDL efforts (Chisel/Chipyard, SpinalHDL, Amaranth, Clash).
We argue that the audit trail — spec commit + generated commit + drift-guard
CI run — is the primitive that lets a mesh fabric claim verifiability without
retroactive proof work. Pre-silicon numbers are labelled `-sim` throughout.

## 1. Thesis (δ-thesis)

**A proof is only as good as its spec.** [Carrone 2026](https://federicocarrone.com/articles/formal-verification-moves-trust/) makes this argument for formal verification generally: verification does not eliminate trust, it moves trust into (a) the specification, (b) the model of the environment, and (c) the trusted computing base underneath the verifier.

We take this seriously for mesh networking:

1. If the spec is opaque or absent, downstream proofs, benchmarks, and audits
   reduce to trust-in-implementation.
2. If the spec is present but generated code drifts from it silently, every
   claim about the code is a claim about the drifted artifact, not the spec.
3. If both spec and generated code are present, versioned, and diff-checkable
   in CI, the audit trail becomes the primary artifact of the system.

Tri-Net's contribution is the third case, implemented end-to-end at the
codegen level, and extendable to the HDL / bitstream level.

## 2. Related work (fetched sources; every claim has a URL)

### 2.1 Mesh + formal methods (Wave-N3 landscape)

- [Mesh Inference: A Formal Model of Collective Inference Without a Center](https://arxiv.org/abs/2606.19537v2) (Wu et al., 2026-06-17) — first formal characterization of center-free collective inference under observation-only coupling; adjacent to our fabric-level guarantees.
- [MAREF / TLA+ coverage](https://wpnews.pro/news/not-tested-proved-why-maref-uses-tla-formal-verification) (wpnews.pro, 2026-06-16) — cites CISA + Five Eyes May 2026 joint guidance recommending formal methods for agentic AI; MAREF uses TLA+ to prove properties of multi-agent workflows.
- [SLD-Spec Framework](https://www.ijert.org/sld-spec-framework-a-multi-modal-approach-for-automating-and-verifying-formal-specifications-in-high-integrity-software-ijertconv14is060116) (IJERT, 2026) — multi-modal spec generation + verification for high-integrity software; overlaps our spec-first posture but stops at software, not fabric.
- [D-Central H1 2026 mesh report](https://d-central.tech/reports/mesh-off-grid-sovereignty-2026-h1/) — landscape review of Meshtastic + Nostr + Reticulum for off-grid sovereignty; contextualizes the mesh side.
- [Reticulum migrated to GRICAD GitLab](https://gricad-gitlab.univ-grenoble-alpes.fr/meshtastic/reticulum/-/tree/main) — sovereignty signal in the mesh stack ecosystem.

### 2.2 Reproducible HDL / spec-to-hardware

- [RISC-V HDL Tournament — Battle of HDLs](https://www.minres.com/riscv-tournament-battle-of-hdls/) (MINRES, 2026-06-17) — comparative frame for Chisel/Chipyard, SpinalHDL, Amaranth, Clash. Directly maps to the space Tri-Net will occupy for its HDL back-end.

### 2.3 Adjacent competing narratives

- [Qualcomm AI-driven Wi-Fi mesh patent](https://patentlyze.com/patent/ai-driven-wi-fi-mesh-network-configuration/) (2026-06-25) — competing "AI configures mesh" narrative; orthogonal to our "spec drives mesh" narrative, but occupies the same discourse space.

## 3. System description (what Tri-Net actually ships)

### 3.1 SSOT contract

- `specs/wire.t27` in the T27 language is the single source of truth for wire framing.
- `t27c gen-{rust,zig,c} specs/wire.t27` produces `gen/{rust,zig,c}/wire.{rs,zig,c}` byte-for-byte deterministically (63 / 73 / 128 lines respectively at tri-net HEAD `dc1bebb`).
- `build.rs` refuses to overwrite committed generated code (comment now reframed as intentional: drift-guard, not stubs, is the enforcement mechanism).

### 3.2 Drift-guard CI (multi-target)

- Workflow: [`.github/workflows/spec-drift-guard.yml`](https://github.com/gHashTag/tri-net/blob/main/.github/workflows/spec-drift-guard.yml) — initial version in [tri-net#35](https://github.com/gHashTag/tri-net/pull/35), extended to three backends in [tri-net#38](https://github.com/gHashTag/tri-net/pull/38).
- Trigger: `push` to main + PR touching `specs/**`, `gen/**`, `build.rs`, or the workflow itself.
- Action: rebuild `t27c` from `gHashTag/t27@master`, regenerate three files in-place, `diff -u` against committed on each. Any of the three mismatching fails the job with a per-file `::error` annotation.
  - `gen/rust/wire.rs` — via `t27c gen-rust`.
  - `gen/zig/wire.zig` — via `t27c gen`.
  - `gen/c/wire.c` — via `t27c gen-c`.
- Consequence: silent drift between spec and generated code cannot land on any of the three text backends.

### 3.3 Bootstrap history — ExprCast resolved on all four backends

- Rust — [t27#1320](https://github.com/gHashTag/t27/pull/1320) at `bootstrap/src/compiler.rs:8172`, emits `({operand} as {target})`.
- Zig — [t27#1337](https://github.com/gHashTag/t27/pull/1337), emits `@as(<T>, @intCast(<operand>))` (narrows and widens).
- C — [t27#1337](https://github.com/gHashTag/t27/pull/1337), emits `((<uintN_t>)(<operand>))` via `Self::type_to_c`.
- Verilog — already lowered pre-#1320.

All three text backends now round-trip `specs/wire.t27` without falling through the default arm.

## 4. Contribution

C1. **CI-enforced spec/impl equality.** Not a claim, not a proof — a diff. Every merge that touches specs/gen/build must survive the diff. (Post-[#35](https://github.com/gHashTag/tri-net/pull/35), widened to three backends in [#38](https://github.com/gHashTag/tri-net/pull/38).)

C2. **Language-level SSOT** rather than doc-level SSOT. The spec is executable input to a compiler, not English prose.

C3. **In-repo audit trail** for competitive intelligence itself: [docs/COMPETITOR_WATCH_SPEC.md](https://github.com/gHashTag/tri-net/blob/main/docs/COMPETITOR_WATCH_SPEC.md) treats the weekly scan as a repo protocol — same audit posture as code.

C4. **Delta (δ) between our thesis and the field:**
   - vs. Reticulum / Meshtastic: they ship code, we ship spec-then-code with a drift-check.
   - vs. MAREF / SLD-Spec: they ship spec-level verification, we ship spec-to-artifact byte-identity, no theorem prover required for the SSOT claim itself.
   - vs. Chisel/Chipyard/SpinalHDL/Amaranth/Clash: they generate HDL from higher-level DSLs; we plan to generate wire logic + HDL from the same T27 spec (future work, Section 7).

## 5. Reference implementation (empirical realization of the audit-trail primitive)

Sections 1–4 describe the auditability primitive in the abstract: one spec, N generated artifacts, a diff-based enforcement mechanism, and a fixed tuple of commits a third party can fetch to re-derive every artifact. This section reports the concrete artifact that instantiates the primitive, so the paper is not "we propose X" but "we propose X and here is a working reference that anyone can rerun today."

### 5.1 What is materialized

At tri-net main [`dc1bebb`](https://github.com/gHashTag/tri-net/commit/dc1bebb) and t27 master [`3c912d9`](https://github.com/gHashTag/t27/commit/3c912d9):

- **One SSOT spec**: [`specs/wire.t27`](https://github.com/gHashTag/tri-net/blob/main/specs/wire.t27) — mesh datagram framing (11-byte header, big-endian src/dst, ttl, kind), constants + predicates + byte-layout functions in the T27 language.
- **Three generated backends**, all committed and all under drift-guard:
  - [`gen/rust/wire.rs`](https://github.com/gHashTag/tri-net/blob/main/gen/rust/wire.rs) — 63 lines, `t27c gen-rust`.
  - [`gen/zig/wire.zig`](https://github.com/gHashTag/tri-net/blob/main/gen/zig/wire.zig) — 73 lines, `t27c gen`.
  - [`gen/c/wire.c`](https://github.com/gHashTag/tri-net/blob/main/gen/c/wire.c) — 128 lines, `t27c gen-c`.
- **One CI workflow** enforcing byte-identity on all three: [`.github/workflows/spec-drift-guard.yml`](https://github.com/gHashTag/tri-net/blob/main/.github/workflows/spec-drift-guard.yml).
- **Consumer path under the same umbrella**: [`src/wire.rs::Header::parse`](https://github.com/gHashTag/tri-net/blob/main/src/wire.rs) delegates to auto-gen `u32_be`, so the parse-side big-endian reassembly is also traced back to the spec (see [tri-net#37](https://github.com/gHashTag/tri-net/pull/37)).

### 5.2 The audit-trail tuple (concrete instance)

Section 6 sketches the audit-trail primitive abstractly. The current concrete instance a third party needs is:

```
tri-net    main       @  dc1bebb
t27        master     @  3c912d9
workflow   run                (any run of spec-drift-guard on dc1bebb; visible in Actions tab)
```

Given this tuple, the third party can rerun the recipe in Appendix A locally and independently confirm byte-identity on all three generated files. No paper, no README, no maintainer testimony is between the spec and the artifact.

### 5.3 Merge chain that produced the reference implementation

| PR | Merged @ | Contribution |
|---|---|---|
| [tri-net#33](https://github.com/gHashTag/tri-net/pull/33) | `77a9a49` | T27-first partial flip; `specs/wire.t27` becomes SSOT; `gen/rust/wire.rs` becomes pure t27c output. |
| [tri-net#34](https://github.com/gHashTag/tri-net/pull/34) | `91a5b63` | `docs/COMPETITOR_WATCH_SPEC.md`; in-repo audit protocol for the weekly competitor scan (C3). |
| [tri-net#35](https://github.com/gHashTag/tri-net/pull/35) | `f126dca` | Drift-guard CI for Rust backend. |
| [tri-net#37](https://github.com/gHashTag/tri-net/pull/37) | `0e1f1f2` | Parse-path `u32_be` delegation — `Header::parse` under SSOT umbrella. |
| [tri-net#38](https://github.com/gHashTag/tri-net/pull/38) | `dc1bebb` | Drift-guard extended to Zig + C; commits `gen/zig/wire.zig` and `gen/c/wire.c`. |
| [t27#1320](https://github.com/gHashTag/t27/pull/1320) | t27 `c4dc8ee` | Rust ExprCast emitter. |
| [t27#1337](https://github.com/gHashTag/t27/pull/1337) | t27 `3c912d9` | Zig + C ExprCast emitters. |

Each row is publicly linked, squash-merged, and reachable from a signed commit on `main`/`master`.

### 5.4 Empirical checks that pass at HEAD

At tri-net `dc1bebb`, verified in-CI on [PR #38](https://github.com/gHashTag/tri-net/pull/38) (`spec-drift-guard` job, conclusion SUCCESS) and reproducible locally:

- `t27c gen-rust specs/wire.t27 | diff -u gen/rust/wire.rs -` → empty.
- `t27c gen       specs/wire.t27 | diff -u gen/zig/wire.zig -` → empty.
- `t27c gen-c     specs/wire.t27 | diff -u gen/c/wire.c    -` → empty.
- `grep -c 'unsupported: ExprCast' gen/zig/wire.zig gen/c/wire.c` → 0 / 0.
- `cargo test --lib` → 101 passed / 0 failed (includes `wire::tests::header_roundtrips`, which empirically confirms byte-order equivalence between the parse and serialize paths against the same spec).

Sample of generated cast forms (extracted from the committed files, not fabricated):

- Zig `be_byte`: `return @as(u8, @intCast((w >> 24) & 255));`
- C   `be_byte`: `return ((uint8_t)(((w >> 24) & 255)));`
- Rust `be_byte`: `return (((w >> 24) & 255) as u8);`

### 5.5 What this reference implementation does NOT show

- It does not prove functional correctness of the framing, only spec/artifact byte-identity across three backends.
- It does not extend to the full protocol stack yet — only one spec (`wire.t27`) is under drift-guard today. Each additional spec (routing, discovery, session, physical) needs its own row.
- It does not touch silicon. All numbers in this line of work remain `-sim` until a fabbed part exists (Section 6).
- It does not eliminate trust in `t27c` itself; a compromised `t27c` produces a self-consistent lie. The primitive moves trust from the artifact to the compiler + spec tuple, per Section 1 ([Carrone 2026](https://federicocarrone.com/articles/formal-verification-moves-trust/)).

## 6. Limits and honest scope (Trinity rule: no chip, no TRI)

- **Pre-silicon.** All performance and area numbers in this line of work are `-sim` or `-est` until a fabbed part exists.
- **One spec.** `specs/wire.t27` is one file. The SSOT contract is not yet stated for the full protocol stack; each additional spec (routing, discovery, session, physical) will need its own drift-guard row.
- **No formal proof yet.** Drift-guard is byte-identity across three text backends, not a functional-correctness proof. Section 7 discusses layering property proofs on top.
- **Trust surface of `t27c`.** Drift-guard equates spec and artifact via `t27c` itself; a compromised or non-reproducible `t27c` produces a self-consistent lie. Deterministic-build story for `t27c` is future work (Section 7).
- **No hardware target under drift-guard yet.** Verilog emitter existed pre-#1320 but no `gen/verilog/wire.v` is committed or diffed; adding it is a next step once an HDL target consumes it.

## 7. Future work / paper-scope items

- ~~Extend drift-guard to Zig + C once [t27#1333](https://github.com/gHashTag/t27/issues/1333) lands.~~ — done, [t27#1337](https://github.com/gHashTag/t27/pull/1337) + [tri-net#38](https://github.com/gHashTag/tri-net/pull/38).
- Extend the SSOT contract to additional specs (routing / ETX, discovery, session, physical layer). Each new spec needs its own row in the drift-guard workflow.
- Add functional-property proofs on top of byte-identity (candidate: TLA+ on parsed wire states, matched to [MAREF](https://wpnews.pro/news/not-tested-proved-why-maref-uses-tla-formal-verification) posture).
- HDL emission from T27 (compare positioning to [Chisel/Chipyard, SpinalHDL, Amaranth, Clash](https://www.minres.com/riscv-tournament-battle-of-hdls/)).
- Formalize the audit-trail primitive: what does a third party need to fetch to verify a Tri-Net release end-to-end. Section 5.2 gives a concrete instance; a general definition (spec commit × compiler commit × workflow-run ID → verifiable artifact set) is TBD.
- Trust surface of `t27c` itself — reproducibility of the compiler binary (deterministic build, hash-pinned toolchain), so a third party can bootstrap `t27c` from source and recheck.

## 8. Anchor

phi^2 + phi^-2 = 3.

## Appendix A. Reproducibility recipe (current, three-target)

This is exactly what [`.github/workflows/spec-drift-guard.yml`](https://github.com/gHashTag/tri-net/blob/main/.github/workflows/spec-drift-guard.yml) runs on every relevant PR (see Section 3.2). Local reproduction:

1. `git clone https://github.com/gHashTag/tri-net; cd tri-net; git checkout dc1bebb` (or newer main).
2. `cd ..; git clone https://github.com/gHashTag/t27; cd t27; git checkout 3c912d9` (or newer master).
3. `cargo build --release --manifest-path bootstrap/Cargo.toml --bin t27c`.
4. `cd ../tri-net`.
5. Rust: `../t27/target/release/t27c gen-rust specs/wire.t27 | diff -u gen/rust/wire.rs -`. Expected: empty diff.
6. Zig:  `../t27/target/release/t27c gen       specs/wire.t27 | diff -u gen/zig/wire.zig -`. Expected: empty diff.
7. C:    `../t27/target/release/t27c gen-c     specs/wire.t27 | diff -u gen/c/wire.c    -`. Expected: empty diff.
8. Optional: `cargo test --lib`. Expected: 101 passed / 0 failed.
