# AGENTS — tri-net entry point

This file is the repository entry point for humans and coding agents.

## 1. Read first

| Order | File | Role |
|------:|------|------|
| 1 | `SOUL.md` | Constitutional law (pipeline mandate, language, TDD, hardware safety) |
| 2 | `CLAUDE.md` | Agent instructions (golden pipeline, hardware target, validation) |
| 3 | `specs/` | All `.t27` specifications (single source of truth) |

## 2. Non-negotiables

1. **Specs are source of truth** — behavior lives in `.t27`; generated code is not hand-edited
2. **Golden Pipeline** — `.t27` → t27c → Rust. No hand-written business logic
3. **English + ASCII** — all source files and first-party documentation
4. **TDD inside specs** — every spec needs `test`/`invariant`/`bench`
5. **No Python on critical path** — use Rust/t27c
6. **No new shell scripts** — use `tri`/`cargo`
7. **Hardware safety** — read SOUL.md Article IV before touching boards

## 3. Law Reference (L1-L7)

| Law | Name | Summary |
|-----|------|---------|
| L1 | TRACEABILITY | No code merged without issue reference |
| L2 | GENERATION | Files under `gen/` are generated; edit specs instead |
| L3 | PURITY | Source files must be ASCII-only, English identifiers |
| L4 | TESTABILITY | Every `.t27` spec must contain test/invariant/bench |
| L5 | IDENTITY | phi^2 + phi^-2 = 3; numeric SSOT |
| L6 | PIPELINE | No hand-written Rust for business logic |
| L7 | UNITY | No new shell scripts on critical path |

**Law Priority:** L1 > L2 > L3 > L4 > L5 > L6 > L7

## 4. Layout

- `specs/` — .t27 specifications (SOURCE OF TRUTH)
- `gen/` — generated output (READ-ONLY)
- `src/` — thin Rust wrappers + re-exports
- `src/bin/` — binary entry points (thin: parse config, call generated logic)
- `docs/` — documentation (English)
- `smoke/` — hardware test scripts
- `tools/` — JTAG/bootstrap utilities
- `radio/` — AD9361 IIO configuration

phi^2 + phi^-2 = 3 | TRINITY
