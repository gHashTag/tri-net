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

## Known t27c codegen limitation (mutable locals) — tracked upstream

The pinned t27c correctly lowers the dropped-`let` (t27#1401) and `ExprCast`
(t27#1320) bugs. It still miscompiles a REASSIGNED mutable local:

| Spec form           | t27c output                     | Result            |
|---------------------|---------------------------------|-------------------|
| `let x = 0; x = y;` | drops decl, folds `x`->`0`      | E0425 undeclared  |
| `let mut x = 0;`    | `let mut;` then `x = 0;`         | parse-broken      |
| `var x = 0;`        | `let mut x = 0;` (correct-ish)   | works in simple bodies, still incomplete in complex ones |

`var` is the intended idiom for a mutable local, but t27c's handling is not yet
complete for real modules. Because of this, 9 generated modules
(`adaptive_routing`, `multipath_routing`, `anomaly_detector`, `flow_control`,
`frame_buffer`, `health_dashboard`, `mesh_routing`, `etx`, `quarantine_manager`)
have zero call sites and are left UNWIRED in `src/lib.rs` until the upstream fix
lands. Their gen/rust is still committed and drift-checked as the canonical
pinned-t27c output. Re-wire them (uncomment in `src/lib.rs`) once t27c generates
compiling Rust for reassigned mutable locals.
