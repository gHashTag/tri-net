# The golden pipeline — the ONLY correct way to change this repo

`specs/*.t27`  ->  `t27c gen-rust`  ->  `gen/rust/*.rs`  ->  used by `src/`

Anchor: phi^2 + phi^-2 = 3.

## Hard rules (physically enforced — see "Enforcement" below)

1. Logic is written in `.t27` specs. Never hand-write Rust in `gen/`.
2. `gen/rust/*.rs` is GENERATED ONLY, by the pinned compiler in `.t27c-version`.
   It must be byte-identical to `t27c gen-rust <spec>` from that exact commit.
3. To change generated behaviour: edit the `.t27` spec, regenerate, commit both.
4. Never push to `main` directly. All changes land through a pull request whose
   checks pass. (`main` is a protected branch; direct pushes are rejected.)
5. Bump `.t27c-version` only together with a full regen of `gen/rust` in the
   same commit.

## Regenerate locally

```bash
# 1. Build the pinned t27c
SHA=$(grep -oE '[0-9a-f]{40}' .t27c-version | head -1)
git clone https://github.com/gHashTag/t27 ../t27 && git -C ../t27 checkout "$SHA"
cargo build --release -p t27c --manifest-path ../t27/Cargo.toml

# 2. Regenerate every module from its spec
for spec in specs/*.t27; do
  n=$(basename "$spec" .t27)
  ../t27/target/release/t27c gen-rust "$spec" > "gen/rust/$n.rs"
done

# 3. Verify nothing drifted, then build/test
git diff --exit-code -- gen/rust/
cargo build --all-targets && cargo test
```

`build.rs` performs the same regeneration automatically when the pinned t27c is
present at `../t27/target/release/t27c`.

## Enforcement (what makes the wrong way physically impossible)

- `.github/workflows/spec-drift-guard.yml` rebuilds t27c at the pinned commit,
  regenerates all `gen/rust`, and FAILS the build on any byte drift, then
  builds + tests. Catches: stale/wrong compiler, hand-edited gen, spec edited
  without regen.
- `.github/workflows/ci.yml` runs fmt + clippy (`-D warnings`) + build + test +
  `cargo-audit`.
- Branch protection on `main`: no direct pushes, PR required, required status
  checks must pass, no bypass. This is what would have stopped the 2026-07-07
  breakage (a direct push of gen/rust built by a stale t27c).
- `lefthook.yml` pre-commit hooks are a local first line (no gen/ edits, no
  hand-written logic in `src/`, ASCII-only) but hooks are bypassable, so CI +
  branch protection are the real guard.

## t27c codegen fixes applied (pinned commit d7f3a73)

The pinned t27c carries, in order: the dropped-`let` lexer fix (t27#1401), the
`ExprCast` fix (t27#1320), the **optimizer removal for the Rust/C source
backends** (t27#1456 — the AST optimizer was dropping reassigned mutable locals
and const-inlining `let`), and the **array/index codegen fix** (t27#1457 —
`[T; N]` -> `[T; N as usize]`, non-literal indices cast to `usize`).

With these, all 68 specs regenerate to compiling Rust. The 9 generated mesh
modules (`adaptive_routing`, `multipath_routing`, `anomaly_detector`,
`flow_control`, `frame_buffer`, `health_dashboard`, `mesh_routing`, `etx`,
`quarantine_manager`) are now WIRED in `src/lib.rs`. They still have zero call
sites, so each `mod` declaration carries `#[allow(dead_code, unused,
unused_parens, clippy::all)]` for lint hygiene on generated theater.

Genuine SOURCE-spec bugs surfaced by the now-correct codegen were fixed in the
`.t27` specs (see gHashTag/tri-net#61): a `path_valid` typo, an
`is_multipath_viable` bool-vs-u32 return type, an `etx` Q8.8 `256`-in-u8 literal,
and ~50 reassigned locals switched from `let` to the mutable idiom `var`.

The pin is `d7f3a73` on branch `fix/faithful-rust-c-codegen-1455`; once
t27 PR #1456 merges to master, bump `.t27c-version` to the master SHA (the
generated output is identical).
