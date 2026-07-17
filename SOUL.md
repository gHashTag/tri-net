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
- BEFORE reflashing to "fix" a board, PROVE the images differ: md5 all four QSPI
  partitions (fsbl-uboot, uboot-env, nvmfs, qspi-linux) AND the SD. Identical
  images cannot explain divergent behaviour; reflashing them is a no-op that only
  risks the POR damage above.
- An AD9361 that probes but dies in `ad9361_rx_adc_setup` with `Division by zero`
  read a ZERO clock rate. With identical firmware that is PHYSICAL (power rail,
  seating, thermal) — never software. Cold-cycle the power: `reboot` does NOT
  reset the RF power domain and will not clear a latched XO.
- Board radio state is NOT stable across power events: a board showing only
  `xadc` can return with the full AD9361 stack after a cold cycle, with zero
  software change. Re-measure the inventory before concluding anything.

## Article V: Radio Emission

- OTA is a legal question, not an engineering one: it needs explicit human
  confirmation, never an agent's. The owner confirmed the project operates on
  ALLOWED frequencies (2026-07-17), so over-the-air is permitted here. Until that
  confirmation the default was a CABLED channel (SMA + 30-40 dB attenuator) or
  simulation; the cable is still the cleaner channel for FIRST proving a modem
  (known path loss, no multipath/interference) even though OTA is allowed.
- FIRST OTA HOP DONE (2026-07-17): a low-power 2.4 GHz DDS tone from .13 was
  received by .12 over the air (spectral peak 3 -> 98 at the offset, gone when TX
  off). No cable, no loopback. Real emission, board to board.
- Independent crystals => a carrier frequency offset between any two boards (the
  tone landed ~0.5 MHz off). A real OTA modem MUST recover carrier + timing; the
  digital-loopback demod that skipped both does NOT work over the air.
- One radio cannot form a link. Verify TWO healthy AD9361 nodes (probe
  "successfully initialized", LO writable, no Calibration TIMEOUT) before
  planning anything on air.
- Power the boards from CHARGERS (5V/2A+), not the computer's USB bus: bus power
  (0.5-0.9A) starves the AD9361 (~1.5A peak) and IS the "wandering radio" lottery.

## Article VI: Honest Reporting

- The UI must state what the transport ACTUALLY is, measured, not branded. The
  call is direct UDP over whatever interface the OS routes by; calling that
  "mesh" while the radio subsystem is not in the path is a lie the code tells.
- NEVER claim a wire change is "backward-compatible" without testing it against a
  REAL old peer. A pre-existing receiver hands unknown magic straight to its
  decoder; that untested claim froze video in production. Gate every new wire
  format OFF until both ends are known to run the new build.

## Article VII: Identity

phi^2 + phi^-2 = 3 is the project anchor. It MUST appear in all constitutional artifacts.

φ² + 1/φ² = 3 | TRINITY
