# W7.1 Investigation — root cause of E0425 in tri-net Rust codegen

> phi^2 + phi^-2 = 3

## Status

**Findings-only.** No code change in this branch yet. This document establishes the root cause of the 2609-site E0425 defect and prepares the upstream issue text. The Rust regen and re-sweep happen only after the upstream fix in [`gHashTag/t27`](https://github.com/gHashTag/t27) lands.

## Bottom line

The Rust text-emitter in `t27c` drops **every** `let` statement from generated function bodies. Every body-reference to a name that was bound by `let` in the spec becomes an undeclared identifier in the emitted Rust — that is E0425.

Across the 68 modules in `tri-net@feat/strategic-audit-2026-07-04` this single defect accounts for **2609 of 2813 E0425 sites — 93% of all Rust errors, spanning 49 of 68 modules**.

## Reproducer (one function, minimal)

Spec — `specs/access_control.t27`, lines 74–77:

```
fn check_access(policy: u32, role: u32) -> u32 {
    let min_role = get_min_role(policy);

    if (!role_meets_minimum(role, min_role)) {
        return DENY;
    }
    // ...
}
```

Generated Rust — `gen/rust/access_control.rs`, lines 66–69:

```rust
pub fn check_access(policy: u32, role: u32) -> u32 {
    if !(role_meets_minimum(role, min_role)) {
        return DENY;
    }
    // ...
}
```

The `let min_role = get_min_role(policy);` line is absent from the generated body. On the next line, `min_role` is a free variable → rustc E0425.

## Scope check — 10 spec/gen pairs on the audit branch

| Module | `let` in spec | `let` in gen/rust |
|---|---:|---:|
| access_control | 11 | 0 |
| adaptive_retry | 13 | 0 |
| adaptive_routing | 14 | 0 |
| anomaly_detector | 47 | 0 |
| cache_management | 49 | 0 |
| link_quality_monitor | 22 | 0 |
| multipath_router | 19 | 0 |
| byte_utils | 0 | 0 |
| routing | 0 | 0 |
| daemon | 0 | 0 |
| crypto | 0 | 0 |

Every module whose spec uses `let` emits zero `let` statements in Rust. Modules whose spec has zero `let`s are unaffected by this specific defect (they may still fail for other reasons, per the audit taxonomy).

Command to reproduce (from tri-net checkout, on branch `feat/strategic-audit-2026-07-04`):

```
for f in specs/*.t27; do
  m=$(basename "$f" .t27)
  s=$(grep -c '^\s*let ' "$f")
  g=$(grep -c '^\s*let ' "gen/rust/$m.rs" 2>/dev/null || echo 0)
  printf "%-30s spec:%3d gen:%3d\n" "$m" "$s" "$g"
done
```

Expected output: any module with `spec > 0` shows `gen = 0`.

## Suspected upstream location

The Rust text-emitter's statement-lowering visitor is missing (or falling through the default arm on) the `Stmt::Let` AST node. This mirrors the shape of the earlier ExprCast omission (t27#1320) — a specific AST kind is silently unhandled and produces output-shape drift instead of an emit-time error.

Recommended upstream investigation:

- Search the Rust emitter for statement handling; check whether `Stmt::Let` (or `LetBinding` / `Local` / equivalent) is absent from the match or maps to empty output.
- Cross-check the C emitter for the same defect — the audit reports 1957 undeclared-identifier sites in C, which is consistent with a shared `let`-drop across Rust and C text emitters.
- Once the missing-`types.zig` blocker (audit §Defect 7) is resolved, verify the Zig emitter against the same reproducer.

## Cross-backend note

- **Rust**: 2609 E0425 sites, 49 / 68 files affected. Root cause verified above.
- **C**: 1957 undeclared sites — very likely the same root cause. Not yet independently reproduced against the C emitter's source, but should be checked in the same upstream fix.
- **Zig**: blocked upstream by missing `types.zig` emission (separate defect); `let`-drop cannot be exercised until Zig files reach body analysis.

## Expected impact after upstream fix

- Rust: `19 / 68 OK → substantially more OK`. Precise number depends on residual defects (Class 2 Vec<>, Class 3 cross-width comparison, Class 4 integer literal overflow, Class 5 reserved-word collision — all documented in the audit).
- E0425 drops from 2609 sites to a small residual (only sites not caused by `let`-drop).

## Success criterion for the tri-net regression check

After the upstream fix, tri-net regenerates `gen/rust/` and reruns `scripts/audit/rust_compile_sweep.sh`. Both conditions must hold:

1. Rust fail count drops from 49 / 68 to well below 20 / 68.
2. The **error-code histogram** post-fix does not introduce new error classes that were previously masked by E0425. If some E0308 (cross-width comparison), E0308 (mismatched types), or other classes were being hidden behind earlier E0425 blocks in the same file, that must be documented, not silently accepted.

Point 2 is the check user recommended in the W7.1 kickoff note. It matters because a naive «49 → ≪20» pass-count criterion could hide a regression where E0425 was upstream of E0308 in translation order; fixing E0425 lets E0308 finally surface. That is progress, not regression, but it must be explicitly reported.

## Next steps

1. Reviewer approves this investigation document (against committed text on this branch — `w7/compiler/e0425-fix`, following the W7 no-paste-review rule ratified in PR #43).
2. Open upstream issue in [`gHashTag/t27`](https://github.com/gHashTag/t27) with the reproducer and scope check. Draft body prepared; awaiting explicit go-ahead before publishing to an external repo.
3. Upstream fix in `t27c` lands (external timeline).
4. Regenerate `gen/rust/` on tri-net, rerun sweep, produce histogram delta report, land W7.1 PR in tri-net with the regen + audit-doc update.

## Cross-repo dependency (user-flagged)

Per W7.1 kickoff note: this workstream stalls if the upstream `t27c` fix is delayed. In that case W7.3 (grammar fuzzer v2 baseline) can start in parallel on the current broken-tree without regen dependency, since fuzz testing exercises the spec parser, not the generated code compilability.

## Reproducibility

- Audit data source: `tri-net@feat/strategic-audit-2026-07-04`, commit `bf50ad64`.
- Investigation commands: shown inline above (the `for f in specs/*.t27` loop).
- All 10-module sample values were produced by `git show origin/feat/strategic-audit-2026-07-04:<path>` runs during the investigation, not by paste.
