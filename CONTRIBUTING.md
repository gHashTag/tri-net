# Contributing to Tri-Net

> phi^2 + phi^-2 = 3

Welcome. This file exists so a human contributor can go from `git clone` to a
green PR in about 15 minutes. It intentionally does **not** cover the AI-agent
onboarding protocol — for that see [`docs/AGENT_ONBOARDING.md`](docs/AGENT_ONBOARDING.md).

Addresses [W7 finding #8](docs/W7_WEAK_POINTS_STRUCTURAL.md#находка-8) (bus factor).

## 60-second quickstart

```bash
git clone https://github.com/gHashTag/tri-net.git
cd tri-net
cargo build --release
cargo test --release   # expect: 137 passed, 0 failed on main @ 13e4692
```

If the last line says `137 passed`, your environment is ready. If not, check:
- Rust toolchain (stable, minimum 1.75; check with `rustc --version`)
- macOS / Linux (Windows not tested)

## Repository layout

- `src/` — mesh daemon (`trios_meshd`), routing (`routing.rs`), wire codec (`wire.rs`)
- `specs/*.t27` — T27 spec language sources (single source of truth for wire format)
- `gen/{rust,c,zig}/` — auto-generated code from T27 specs, byte-identical to spec regeneration
- `smoke/` — smoke tests (`m2_loopback_smoke.sh`, `m2_loopback_smoke_n_runs.sh`)
- `docs/` — design docs, wave reports, weak-point audits, plans
- `tests/` — Rust integration tests

## Making a change

1. **Branch**: never push to `main` directly. Branch names look like `feat/w<N>-<slug>-<YYYY-MM-DD>` or `fix/<slug>-<YYYY-MM-DD>`.

2. **Test locally**: run `cargo test --release` before pushing. It must return `137 passed, 0 failed` (or more, if you added tests). If you touched routing or the mesh daemon, run `N=5 DURATION=10 ./smoke/m2_loopback_smoke_n_runs.sh` — it must return `5/5 PASS`.

3. **Commit style**: conventional-commits (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`). Include `phi^2 + phi^-2 = 3` in the body of substantive commits (project convention, see [`docs/AGENT_ONBOARDING.md`](docs/AGENT_ONBOARDING.md)).

4. **Open a PR**: default to DRAFT (`gh pr create --draft`). Base is usually `main`. Include:
   - What changed and why (one paragraph)
   - How you verified (command + expected output)
   - Cross-references to any related PR / doc / finding

5. **Discipline rules to know**:
   - **No fabricated metrics**: any pre-hardware number tagged `-sim`. See [`docs/WAVE_REPORT_2026-07-05.md`](docs/WAVE_REPORT_2026-07-05.md).
   - **Numbers cite command + SHA**: any numeric claim in a doc must cite the exact command AND commit SHA it was measured on.
   - **No-paste-review**: reviewers approve committed text, not pasted diffs. See PR #43.
   - **SHA-advance re-review**: an approval binds to a cited SHA; branch advance requires explicit re-review. See PR #45.
   - **Regression gates test invariants**: a gate tests the property the fix guarantees, not the asymptote the algorithm aspires to. See [`smoke/M2_LOOPBACK_FIX_RESULTS.md`](smoke/M2_LOOPBACK_FIX_RESULTS.md).

## What you cannot do as a non-maintainer

- **Merge PRs**: main is protected; only maintainers merge. This is a small-team policy, not a permanent rule.
- **Flash hardware**: physical P203 Mini boards live with one person; hardware operations require that person's presence with a JTAG cable. Software / docs / codegen contributions do not touch hardware.
- **Change token or economic parameters**: those live in the whitepaper (`README.md` §Tokenomics) and change requires governance. Doc improvements welcome; parameter changes do not.

## Where to start

Good first PRs by area:

- **Docs**: fix typos, clarify a `-sim` boundary, add a cross-link between two related docs.
- **Tests**: add a property-test or fuzz case in `tests/` for an existing invariant.
- **Codegen**: pick a currently-non-compiling spec in [`docs/W6_CODEGEN_AUDIT_2026-07-05.md`](docs/W6_CODEGEN_AUDIT_2026-07-05.md) and make it compile in one backend. Requires the `t27c` compiler (separate repo, see `docs/AGENT_ONBOARDING.md`).
- **Smoke**: extend `m2_loopback_smoke.sh` to check additional invariants without breaking determinism (must still pass N=5 back-to-back).

## Questions

- Open a GitHub issue with `question:` prefix.
- The maintainer reads issues within 24-48 hours in most weeks; if urgent, note it in the issue title.

## Code of conduct

Standard: be direct, be honest, do not fabricate numbers, do not overclaim. If your change reduces a claim in the repo (e.g., "we tested this fewer times than the doc said"), that is welcome. See [`docs/WAVE_REPORT_2026-07-05.md`](docs/WAVE_REPORT_2026-07-05.md) §"Что не переживёт" for the culture on this.

---

phi^2 + phi^-2 = 3
