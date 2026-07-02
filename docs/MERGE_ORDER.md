# Merge-Order Runbook — open PR stack (as of 2026-07-02)

> **Purpose.** Seven PRs (#11–#17) are open at once, and several **physically overlap the same files**.
> GitHub shows every one as `mergeable: clean`, but that is an illusion — `main` has not moved yet.
> The moment one PR in an overlapping group lands, the others in that group hit a conflict.
> This runbook is the **human merger's checklist**. The agent does **not** merge; a human does.
>
> Anchor: φ² + φ⁻² = 3 · License: Apache-2.0

---

## TL;DR merge order

1. **Mesh stack** — merge **#13 first**, then **close #11 and #12 as superseded** (their content is already inside #13).
2. **PHY stack** — merge **#14**, then **#15** (strictly in that order; #15 is based on `feat/modem`, not `main`).
3. **Independent** — **#16** (crypto ratchet) and **#17** (gf16 host model) touch disjoint files; merge either any time, resolving only a tiny `lib.rs` / `Cargo.toml` seam if they land after the mesh stack.

Rebase every not-yet-merged branch onto the updated `main` after each group lands.

---

## The three groups and why order matters

### Group A — mesh data plane (#11, #12, #13) — **file overlap, pick one path**

| PR | Branch | Base | Touches |
|----|--------|------|---------|
| #11 | `feat/wmewma-etx` | `main` | `src/routing.rs` |
| #12 | `feat/m2-router` | `main` | `src/lib.rs`, `src/router.rs` |
| #13 | `feat/meshd` | `main` | **superset** of #11 + #12 + `daemon.rs`, `bin/`, `radio/`, `smoke/` |

**#13 physically contains the #11 (`routing.rs`) and #12 (`lib.rs`, `router.rs`) changes.** All three
report `clean` only because `main` has not moved. Merge any one and the other two conflict.

- **Path A (recommended, simplest):** merge **#13 first** → close **#11** and **#12** as *superseded*.
  Before closing, confirm the WMEWMA routing and the router inside #13 are identical to the final
  #11 / #12 versions (they were, at review time).
- **Path B (preserve history):** #11 → #12 → #13, rebasing #13 after each. Conflicts are trivial
  because the changes coincide, but it is more work for no code benefit.

### Group B — radio PHY (#14, #15) — **strict linear order**

| PR | Branch | Base | Touches |
|----|--------|------|---------|
| #14 | `feat/modem` | `main` | `src/lib.rs`, `src/modem.rs`, `Cargo.toml` |
| #15 | `feat/radio-phy` | **`feat/modem`** | `src/lib.rs`, `src/modem.rs` |

**#15's base is `feat/modem` (#14), not `main`.** Merge **#14 first**, always. GitHub shows #15 as
`clean` relative to #14, not relative to an updated `main`. After #14 lands in `main`, **rebase #15
onto `main`** before merging it.

### Group C — independent (#16, #17) — **no ordering constraint**

| PR | Branch | Base | Touches |
|----|--------|------|---------|
| #16 | `feat/ratchet-zeroize` | `main` | `src/crypto.rs`, `src/daemon.rs`, `Cargo.toml` |
| #17 | `feat/gf16-ofdm-model` | `main` | `src/gf16.rs` (new), `src/lib.rs` (+2), `Cargo.toml`, `README.md`, `tests/`, `scripts/` |

Both are additive and touch files the mesh/PHY stacks barely share. Merge any time. If they land
**after** Group A/B, expect at most a one-minute manual seam:

- **`src/lib.rs`** — the `pub mod …;` and `pub use …;` lists. #12/#13/#14/#15/#17 each add lines here.
  Conflicts are line-adjacency only; keep all module declarations and re-exports.
- **`Cargo.toml`** — `[dependencies]` / `[dev-dependencies]` / `[features]`. #14 adds `num-complex`;
  #16 adds/keeps crypto deps; #17 adds `serde`/`serde_json` dev-deps and a `[features]` block. Union them.

---

## Cross-cutting conflict seams (whoever merges second fixes these)

| File | Contending PRs | Resolution |
|------|----------------|------------|
| `src/lib.rs` (`pub mod` / `pub use`) | #12, #13, #14, #15, #17 | Keep **all** module declarations + re-exports; it is a union, not a choice. |
| `Cargo.toml` (`[dependencies]`/`[features]`) | #14, #16, #17 | Union the dependency and feature entries; drop nothing. |
| `src/routing.rs` | #11, #13 | Resolved by closing #11 as superseded (Path A). |
| `src/router.rs`, `src/lib.rs` | #12, #13 | Resolved by closing #12 as superseded (Path A). |
| `src/modem.rs` | #14, #15 | Resolved by strict #14→#15 order + rebase. |

---

## Per-merge checklist (run for every PR before landing)

- [ ] `git fetch origin && git rebase origin/main` on the PR branch (Group B: rebase #15 onto `main` **after** #14 lands).
- [ ] `cargo fmt --all --check` — no diff.
- [ ] `cargo clippy --all-targets -- -D warnings` — clean.
- [ ] `cargo test --verbose` — all green (mirror the CI `build + test (-sim baseline)` job).
- [ ] GitGuardian Security Checks — pass.
- [ ] Re-open the PR page and confirm `mergeable` is still `clean` **against the moved `main`**, not stale.
- [ ] Squash-or-merge, then immediately rebase the next branch in the same group.

---

## Honesty register (do not weaken on merge)

These PRs use a deliberate **sim vs. hardware** register. Merging must not upgrade a label:

- **#13** is the only PR with **verified-on-hardware** claims (M1 crypto-smoke on P201Mini, AD9361 5.8 GHz
  digital loopback, M3 mesh 11→13 over Ethernet — owner-confirmed 2026-07-01). Its `hw ✅` labels are honest.
  Everything else in #13 — full OFDM PHY in the FPGA PL, TDMA, flights — stays **not on hardware**.
- **#11, #12** — host-tested routing/data-plane logic. No hardware claim.
- **#14, #15** — PHY host models, explicitly `host-tested` / "no OTA under Thai rules". No hardware claim.
- **#16** — crypto ratchet + zeroize, host-tested. No hardware claim.
- **#17** — GF16 host DSP model; the win is multiplier **width/area**, **not accuracy**. Verified in
  simulation only. No hardware, no RTL, no bitstream.

**Rule:** "verified in simulation" ≠ "running on hardware." Keep every PR's label as-merged.

---

_This runbook is documentation only. The agent proposes; a human merges._
