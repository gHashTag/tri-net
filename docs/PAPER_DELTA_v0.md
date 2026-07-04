# δ-Paper (draft skeleton v0): Verifiable Mesh Fabric — Spec-First and Reproducible-HDL Positioning

Status: DRAFT SKELETON — not for external circulation.
Anchor: phi^2 + phi^-2 = 3.
Repo cross-link: gHashTag/tri-net main @ 91a5b63 (post-PR#34).

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
- `t27c gen-rust specs/wire.t27` produces `gen/rust/wire.rs` byte-for-byte deterministically (63 lines at HEAD 91a5b63).
- `build.rs` refuses to overwrite committed generated code (comment now reframed as intentional: drift-guard, not stubs, is the enforcement mechanism).

### 3.2 Drift-guard CI (PR #35, this loop)

- Workflow: `.github/workflows/spec-drift-guard.yml`.
- Trigger: `push` to main + PR touching `specs/**`, `gen/**`, `build.rs`, or the workflow itself.
- Action: rebuild `t27c` from `gHashTag/t27@master`, regenerate `gen/rust/wire.rs` in-place, `diff -u` against committed. Fail with `::error` annotation on mismatch.
- Consequence: silent drift between spec and generated code cannot land.

### 3.3 Bootstrap history — resolved gaps

- `ExprCast` gap in `gen-rust` closed by [t27#1320](https://github.com/gHashTag/t27/pull/1320) at `bootstrap/src/compiler.rs:8172` — emits `({operand} as {target})`.
- Zig + C emitters still have gaps (Zig `_ => {}` silent drop; C `/* unsupported: ExprCast */`) — tracked in [t27#1333](https://github.com/gHashTag/t27/issues/1333). Blocks Zig/C flips but not Rust SSOT.

## 4. Contribution

C1. **CI-enforced spec/impl equality.** Not a claim, not a proof — a diff. Every merge that touches specs/gen/build must survive the diff. (Post-#35.)

C2. **Language-level SSOT** rather than doc-level SSOT. The spec is executable input to a compiler, not English prose.

C3. **In-repo audit trail** for competitive intelligence itself: [docs/COMPETITOR_WATCH_SPEC.md](https://github.com/gHashTag/tri-net/blob/main/docs/COMPETITOR_WATCH_SPEC.md) treats the weekly scan as a repo protocol — same audit posture as code.

C4. **Delta (δ) between our thesis and the field:**
   - vs. Reticulum / Meshtastic: they ship code, we ship spec-then-code with a drift-check.
   - vs. MAREF / SLD-Spec: they ship spec-level verification, we ship spec-to-artifact byte-identity, no theorem prover required for the SSOT claim itself.
   - vs. Chisel/Chipyard/SpinalHDL/Amaranth/Clash: they generate HDL from higher-level DSLs; we plan to generate wire logic + HDL from the same T27 spec (future work, Section 6).

## 5. Limits and honest scope (Trinity rule: no chip, no TRI)

- **Pre-silicon.** All performance and area numbers in this line of work are `-sim` or `-est` until a fabbed part exists.
- **Rust-only SSOT.** Until [t27#1333](https://github.com/gHashTag/t27/issues/1333) closes, only the Rust back-end is spec-driven. C and Zig back-ends drop or emit `/* unsupported */` on `ExprCast`.
- **One spec.** `specs/wire.t27` is one file. The SSOT contract is not yet stated for the full protocol stack; each additional spec will need its own drift-guard entry.
- **No formal proof yet.** Drift-guard is byte-identity, not a functional-correctness proof. Section 6 discusses layering.

## 6. Future work / paper-scope items

- Extend drift-guard to Zig + C once [t27#1333](https://github.com/gHashTag/t27/issues/1333) lands.
- Add functional-property proofs on top of byte-identity (candidate: TLA+ on parsed wire states, matched to [MAREF](https://wpnews.pro/news/not-tested-proved-why-maref-uses-tla-formal-verification) posture).
- HDL emission from T27 (compare positioning to [Chisel/Chipyard, SpinalHDL, Amaranth, Clash](https://www.minres.com/riscv-tournament-battle-of-hdls/)).
- Formalize the audit-trail primitive: what does a third party need to fetch to verify a Tri-Net release end-to-end. Sketch: spec commit + generated commit + drift-guard run ID + t27 master commit.

## 7. Anchor

phi^2 + phi^-2 = 3.

## Appendix A. Reproducibility recipe (current)

1. `git clone gHashTag/tri-net; cd tri-net; git checkout 91a5b63` (or newer main).
2. `git clone gHashTag/t27; cd t27; git checkout master`.
3. `cargo build --release --manifest-path bootstrap/Cargo.toml --bin t27c`.
4. `../t27/target/release/t27c gen-rust specs/wire.t27 > /tmp/wire_regen.rs`.
5. `diff -u ../tri-net/gen/rust/wire.rs /tmp/wire_regen.rs`. Expected: empty diff.

This is the same recipe drift-guard runs on every relevant PR (see Section 3.2).
