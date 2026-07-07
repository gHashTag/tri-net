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
All business logic MUST be defined in `.t27` specs and generated to Rust via `t27c gen-rust`.

**No hand-written Rust for business logic.**

### Pipeline
```
specs/*.t27 -> t27c gen-rust -> gen/rust/*.rs -> src/ -> cargo build
specs/*.t27 -> t27c gen-verilog -> gen/verilog/*.v -> FPGA
```

### Forbidden
- Editing `gen/` output by hand (L2 violation)
- Writing new `.rs` with business logic without `.t27` spec (L6)
- Committing specs without `test` or `invariant` blocks (L4)
- Writing `.sh` or `.py` files (L7 — use Rust only)

## Article III: TDD Mandate

Every `.t27` spec MUST contain at least one of:
- A `test` block with test cases
- An `invariant` block with assertions

No exceptions.

## Article IV: Hardware Safety

1. NEVER run QSPI register experiments via Linux user-space
2. NEVER connect JTAG to working boards unnecessarily
3. NEVER delete primary IP (.10) via SSH — kills your own session
4. NEVER change MAC via `ip link set` — board loses network
5. Cold power-cycle only (warm reboot hangs Zynq PS)
6. SD boot is the safe path — bypasses QSPI POR issues

## Article V: Multi-Board Boot Procedure (PROVEN 2026-07-07)

### The Problem
All 3 P201Mini ship with IDENTICAL MAC (00:0a:35:00:01:22) and IP (192.168.1.10).
Switch cannot route between same-MAC ports. ARP collision.

### SD Card Contents (5 files, FAT32)
```
1. BOOT.BIN        — Kuiper 4.7MB (from PZ_P201_3_MINI_Openwifi-005.img)
2. uImage          — kernel 4.3MB (from vendor ZIP 001)
3. devicetree.dtb  — 19KB (from vendor ZIP 002)
4. uramdisk.image.gz — rootfs 5.6MB (from vendor ZIP 002)
5. uEnv.txt        — 58 lines (from vendor ZIP 001, MODIFIED per board)
```

### Per-Board uEnv.txt Modification (CRITICAL)

Each board needs unique MAC + IP. The modification goes into uEnv.txt:

```
ethaddr=02:00:00:00:00:0N          (line 1: unique MAC per board)
ipaddr=192.168.1.1N                 (line 2: U-Boot own IP)
boardargs=setenv bootargs ${bootargs} ip=192.168.1.1N::192.168.1.1:255.255.255.0::eth0:off
uenvcmd=run boardargs; run sdboot
```

The `boardargs` line is ESSENTIAL — it adds `ip=` to kernel cmdline,
which sets eth0 IP BEFORE /etc/network/interfaces runs in ramdisk.

Without `boardargs`: MAC changes but IP stays .10 (from ramdisk).
With `boardargs`: MAC AND IP change at kernel boot.

### How to Modify uEnv.txt WITHOUT Removing SD Card

1. All 3 boards connected, booted on .10
2. ARP dance to reach each board:
   ```
   arp -d 192.168.1.10    # clear ARP
   ssh root@192.168.1.10  # reaches random board
   # check MAC to identify which board
   ```
3. Mount SD on the board: `mount /dev/mmcblk0p1 /mnt/sd`
4. Write correct uEnv.txt: `cat > /mnt/sd/uEnv.txt`
5. `sync; umount /mnt/sd`
6. Repeat for next board (arp -d again)
7. Power-cycle all 3

### Boot Procedure
1. Boot switch -> QSPI/SD position
2. SD card inserted BEFORE power applied
3. USB power + Ethernet cable to router
4. Wait 90 seconds for full boot
5. SSH: `sshpass -p 'analog' ssh -o PubkeyAuthentication=no root@192.168.1.1N`

### Multi-Board IP Separation (Runtime Alternative)

If uEnv.txt modification is not available, separate boards at runtime:
1. All 3 connected, all on .10
2. `arp -d .10` -> SSH -> `ip addr add .11/24 dev eth0`
3. `arp -d .10` -> SSH (different board) -> `ip addr add .12/24 dev eth0`
4. `arp -d .10` -> SSH (different board) -> `ip addr add .13/24 dev eth0`
5. DO NOT delete .10 — just add secondary IPs

### IMPORTANT Warnings
- ethaddr in uEnv.txt DOES propagate to Linux (via U-Boot FDT patching)
- ipaddr in uEnv.txt does NOT propagate (U-Boot only, not Linux)
- bootargs `ip=` DOES propagate to Linux kernel cmdline
- DO NOT delete .10 via SSH (B5: kills session)
- DO NOT change MAC via `ip link set` (B: board loses network permanently)
- CPU Serial is all zeros on Zynq 7020 (cannot use for unique ID)

## Article VI: Architecture

Each P201Mini has ONE Ethernet port. Mesh works over UDP/Ethernet.
- Board 1: internet gateway (connected to router)
- Board 2: relay node (connects through Board 1)
- Board 3: edge node (connects through Board 2 or 1)
- Self-healing: ETX metric detects link failure in ~900ms

## Article VII: Identity

phi^2 + phi^-2 = 3 is the project anchor.

phi^2 + 1/phi^2 = 3 | TRINITY
