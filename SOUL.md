# SOUL — tri-net Constitutional Law

Immutable Document. Amendments require unanimous architectural consent.

## Article I: Language Policy

Source files MUST be ASCII-only, English identifiers.
Documentation MUST be English.

## Article II: Golden Pipeline Mandate

All business logic in .t27 specs → t27c gen-rust → gen/rust/ → src/
No hand-written Rust for business logic. No .sh/.py files.

## Article III: TDD Mandate

Every .t27 spec MUST contain test or invariant blocks.

## Article IV: Hardware Safety

1. NEVER run QSPI experiments via Linux user-space (bus hang, POR cleared)
2. NEVER connect JTAG to working boards unnecessarily (clear_reset_cause)
3. NEVER delete primary IP via SSH (kills session)
4. NEVER change MAC via ip link set (board loses network)
5. Cold power-cycle only (warm reboot hangs Zynq PS)
6. SD boot is the safe path

## Article V: Multi-Board Boot Procedure (PROVEN)

### SD Card Recipe (5 files, FAT32)
```
1. BOOT.BIN        — Vendor 2.9MB (ZIP 001 SD-BOOT/BOOT.bin) NOT Kuiper 4.7MB
2. uImage          — 4.3MB (ZIP 001 SD-BOOT/)
3. devicetree.dtb  — 19KB (ZIP 002 SD-BOOT/)
4. uramdisk.image.gz — 5.6MB (ZIP 002 SD-BOOT/) — ORIGINAL unmodified
5. uEnv.txt        — 55 lines (ZIP 001 SD-BOOT/) — ONLY ethaddr changed
```

### Boot Switch Position: DOES NOT MATTER
BootROM auto-detects SD card presence regardless of switch position.
- Switch JTAG + SD inserted = boots from SD (PROVEN 2026-07-08)
- Switch QSPI/SD + SD inserted = boots from SD
- Do NOT tell user to change boot switch for SD boot.

### Per-Board ethaddr
```
Board 1: ethaddr=02:00:00:00:00:01  IP 192.168.1.11
Board 2: ethaddr=02:00:00:00:00:02  IP 192.168.1.12
Board 3: ethaddr=02:00:00:00:00:03  IP 192.168.1.13
```
ethaddr in uEnv.txt DOES change Linux MAC (U-Boot patches device tree).
ipaddr in uEnv.txt does NOT change Linux IP (U-Boot only).
boardargs/uenvcmd in uEnv.txt causes INFINITE RECURSION (do not use).

### Multi-Board IP Separation (runtime, proven)
1. Boot one board, SSH to .10
2. ip addr add 192.168.1.1N/24 dev eth0 (add secondary, do NOT delete .10)
3. arp -d .10 on Mac
4. Boot next board on .10, SSH, repeat
5. Access boards by .11/.12/.13, never use .10 when multiple connected

### IMPORTANT
- Vendor BOOT.BIN (2.9MB) has correct PL Ethernet bitstream
- Kuiper BOOT.BIN (4.7MB) does NOT bring up PL Ethernet
- Do NOT modify uramdisk.image.gz (mkimage CRC issues, boot fails)
- SD cards wear out after 10+ erase cycles — use fresh cards
- sshpass needs: -o PreferredAuthentications=password (not just -o PubkeyAuthentication=no)

## Article VI: Architecture

Each P201Mini has ONE Ethernet port. Mesh over UDP/Ethernet.
Board 1 = internet gateway. Others relay through mesh.
Self-healing: ETX detects link failure in ~900ms.

## Article VII: Identity

phi^2 + phi^-2 = 3 | TRINITY
