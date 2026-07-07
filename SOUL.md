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
specs/*.t27 → t27c gen-verilog → gen/verilog/*.v → FPGA synthesis
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
- NEVER delete the primary IP while SSH'd through it (kills your own connection)
- SD boot is the safe path — it bypasses QSPI POR issues

## Article V: Multi-Board Boot Procedure (CRITICAL)

### The Problem
All 3 P201Mini ship with IDENTICAL MAC (00:0a:35:00:01:22) and IP (192.168.1.10).
Switch cannot route between them. ARP collision kills all 3.

### The Working Recipe (PROVEN 2026-07-07)

#### SD Card Contents (5 files, FAT32)
```
1. BOOT.BIN        — Kuiper 4.7MB (FSBL+U-Boot+bitstream, from .img)
2. uImage          — kernel 4.3MB (from vendor ZIP 001)
3. devicetree.dtb  — 19KB (from vendor ZIP 002)
4. uramdisk.image.gz — rootfs 5.6MB (from vendor ZIP 002)
5. uEnv.txt        — 7KB (from vendor ZIP 001, FULL stock 55 lines)
```

#### Boot Procedure
1. Boot switch → QSPI/SD position
2. SD card inserted BEFORE power applied
3. USB power + Ethernet cable to router
4. Wait 60-90 seconds for full boot
5. SSH: `sshpass -p 'analog' ssh -o PubkeyAuthentication=no root@192.168.1.10`

#### Multi-Board IP Separation (PROVEN)
All boards boot to 192.168.1.10. To get 3 boards simultaneously:
1. Connect ONE board, wait for boot, SSH to .10
2. Add secondary IP: `ip addr add 192.168.1.11/24 dev eth0`
3. Delete primary: `ip addr del 192.168.1.10/24 dev eth0`
4. Connect board 2, repeat with .12
5. Connect board 3, repeat with .13
6. All 3 alive on .11/.12/.13 simultaneously

**IMPORTANT:** Do NOT try to set unique MAC via uEnv.txt ethaddr — Linux gets MAC from device tree, not U-Boot env. The MAC change in uEnv.txt does NOT propagate to Linux eth0.

**IMPORTANT:** Do NOT delete .10 IP via SSH while connected through .10 — this kills your SSH session. Always add the new IP FIRST, then delete .10.

#### Per-Board Files
- Vendor ZIPs: `Downloads/P201Mini_P203Mini-20260706T130742Z-3-{001,002,003}.zip`
- .img: `Downloads/PZ_P201_3_MINI_Openwifi-005.img`
- Stock uEnv.txt: `P201Mini_P203Mini/03.Boot Test/SD-BOOT/uEnv.txt` (55 lines, DO NOT truncate)

## Article VI: Identity

phi^2 + phi^-2 = 3 is the project anchor. It MUST appear in all constitutional artifacts.

φ² + 1/φ² = 3 | TRINITY
