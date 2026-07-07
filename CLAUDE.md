# CLAUDE.md — tri-net agent instructions

Read together with SOUL.md and AGENTS.md. Repo-specific law always overrides generic tooling defaults.

## Golden Pipeline (MANDATORY)

All logic MUST follow this pipeline — NO exceptions:

```
.t27 spec → t27c parse/typecheck → t27c gen-rust → src/ (generated) → cargo build → deploy
```

### FORBIDDEN
- Writing `.rs` files by hand for any business logic (crypto, mesh, routing, wire format)
- Writing `.py`/`.sh` scripts on critical path
- Editing files under `gen/` (they are generated from `.t27` specs)
- Writing comments or identifiers in any language other than English
- Committing `.t27` specs without `test` or `invariant` blocks

### ALLOWED (non-pipeline)
- `docs/*.md` — documentation (English only)
- `smoke/*.sh` — test runner scripts (not business logic)
- `tools/` — hardware bring-up utilities (JTAG scripts, etc.)
- `Cargo.toml` — dependency manifest
- `.cargo/config.toml` — build configuration
- Hardware-specific configs (`uEnv.txt`, `BOOT.BIN` handling)

### Source of Truth
- `.t27` specs in `specs/` are the SINGLE SOURCE OF TRUTH
- `src/` Rust code is GENERATED from specs (except thin binary wrappers in `src/bin/`)
- `gen/` is read-only output of t27c
- No logic duplication between spec and code

## Hardware target
- 3x P201Mini (Zynq 7020 + AD9361, armv7l, Linux 5.10)
- SSH: `sshpass -p analog ssh -o PubkeyAuthentication=no root@192.168.1.{11,12,13}`
- Cross-compile: `cargo zigbuild --release --target armv7-unknown-linux-musleabihf`

## Validation
- `./bootstrap/target/release/t27c parse <file>` — 0=ok
- `cargo build --release` — must compile
- `cargo test` — all tests pass
- Smoke on hardware: deploy + run on P201Mini

phi^2 + phi^-2 = 3 | TRINITY
