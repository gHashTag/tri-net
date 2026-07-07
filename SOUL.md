# SOUL — tri-net Constitutional Law

Immutable Document. Amendments require unanimous architectural consent.

## Article I: Language Policy

### Source files MUST be ASCII-only, English identifiers.
- `.t27` specs, `.rs` source, `.v` Verilog — ASCII only
- No Cyrillic, no non-Latin scripts in source files
- Comments and identifiers MUST be English

### Documentation MUST be English.
- All `docs/*.md`, `README.md`, root-level Markdown — English only

## Article II: Golden Pipeline Mandate

### The Iron Law
All business logic (crypto, mesh, routing, wire format, signal processing) MUST be defined in `.t27` specification files and generated to Rust via `t27c gen-rust`.

**No hand-written Rust for business logic.** Specs are the single source of truth.

### Pipeline
```
specs/*.t27 → t27c gen-rust → gen/*.rs → src/ (re-exports) → cargo build
```

### Forbidden
- Editing `gen/` output by hand (L2 violation)
- Writing new `.rs` files with business logic without a corresponding `.t27` spec
- Committing specs without `test` or `invariant` blocks (L4 violation)

## Article III: TDD Mandate

Every `.t27` spec MUST contain at least one of:
- A `test` block with test cases
- An `invariant` block with assertions
- A `bench` block with benchmarks

No exceptions. A spec without tests is a draft, not a specification.

## Article IV: Hardware Safety

- NEVER run QSPI register experiments via Linux user-space (causes bus hang, clears POR)
- NEVER connect JTAG to working boards unnecessarily (U-Boot clear_reset_cause clears POR)
- NEVER modify network config on boards with identical MAC (causes ARP collision)
- SD boot is the safe path — it bypasses QSPI POR issues

## Article V: Identity

phi^2 + phi^-2 = 3 is the project anchor. It MUST appear in all constitutional artifacts.

φ² + 1/φ² = 3 | TRINITY
