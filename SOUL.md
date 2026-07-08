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
5. uEnv.txt        — 56 lines — stock + ethaddr changed + bootargs line appended (see below)
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

### Per-Board IP: kernel bootargs (PROVEN 2026-07-08, survives reboot)
Append ONE line to the stock uEnv.txt (no uenvcmd, no boardargs):
```
bootargs=console=ttyPS0,115200n8 root=/dev/ram rw earlyprintk ip=192.168.1.1N::192.168.1.1:255.255.255.0::eth0:off
```
Stock sdboot's bootm picks up ${bootargs} imported from uEnv.txt; the kernel
brings up eth0 at 192.168.1.1N as PRIMARY. Proven on all 3 boards (M1 3/3 +
M2 three-board mesh PASS). Ready-made files: tools/board-configs/uEnv-boardN.txt.

Leftover: stock init still adds factory .10 as SECONDARY each boot. Drop it
after boot: `ip addr del 192.168.1.10/24 dev eth0`. GOTCHA: if .10 is PRIMARY
(no bootargs ip=), deleting it also flushes all secondaries on the subnet
(promote_secondaries=0) — delete .10 FIRST, then add the unique IP.

NEVER let two boards share a MAC on the wire (switch MAC-flap kills sessions);
duplicate SDs with the same ethaddr caused the 2026-07-08 "board dies" mystery.

### Multi-Board IP Separation (runtime fallback, for stock SDs)
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

## Article VIII: Debugging Doctrine (written in blood, 2026-07-08)

Twenty hours were once spent "fixing" hardware that was never broken.
Every one of the 10 problems in the W12 troubleshooting report was either
self-inflicted (QSPI/JTAG experiments) or a network identity collision
misread as a hardware fault. These laws exist so that never repeats.

1. INDEPENDENT CHANNEL FIRST. Never debug through a signal that lies inside
   the failure domain (the broken-ruler error). If the network is the
   symptom, the console is the instrument: open UART (FT2232H channel B,
   115200, root/analog) as the FIRST command of the session, not the 20th
   hour. dmesg + /proc/cmdline dissolve most "mysteries" in minutes.
2. OBSERVABILITY BEFORE MUTATION. No state change while blind. Read logs,
   read /proc, read the SD from the running board BEFORE rewriting anything.
3. RTFM BEFORE REVERSE-ENGINEERING. Vendor docs first (User Manual, Boot
   Test readme, schematics in ~/Downloads ZIPs), empirics second. Hours of
   JTAG archaeology rediscovered facts printed in the manual - some wrongly.
4. ENUMERATE HYPOTHESIS CLASSES. "Appears briefly then dies" has at least
   three cause classes: hardware, configuration, NETWORK IDENTITY. Write
   all classes down before the first experiment; kill them cheapest-first.
   Confirmation bias is the default failure mode, not the exception.
5. IDENTITY BEFORE SHARED MEDIUM. Two devices with the same MAC or IP on
   one wire poison EVERY network test - including tests of correct fixes
   (a poisoned environment makes correct solutions test as failures).
   `grep ethaddr` on every SD costs one second. Label physical media.
6. ONE VARIABLE PER EXPERIMENT. One board, one cable, one console when
   diagnosing. Three unlabeled boards + full-subnet scans = pure noise.
7. DESTRUCTIVE TOOLS LAST. JTAG, QSPI pokes, register writes come after
   understanding, never before - and NEVER on the last working unit.
   Every destructive mistake adds a new fault layer that will be
   misattributed to the original bug (the compounding spiral).
8. AFTER A DESTRUCTIVE MISTAKE: STOP AND RE-BASELINE. Do not continue the
   original hunt on damaged ground; re-verify what still works first.
9. "PROVEN" REQUIRES REPRODUCTION. One lucky boot is an anecdote. Resolve
   documentation contradictions immediately; never append a second truth
   next to a first one (Kuiper-vs-vendor BOOT.BIN lived unresolved for
   days and corrupted every later session).
10. RUNTIME IS NOT PERSISTENT. `ip addr add` dies at reboot. Every fix
    report MUST state whether it survives a power cycle; a "fixed" that
    silently reverts guarantees a Sisyphus loop next session.
11. KNOWLEDGE MUST SURVIVE SESSIONS. Before declaring "no access" or
    "impossible", search memory and prior docs: the working console recipe
    existed for 7 days while sessions debugged blind. Losing a recipe is
    losing the board.
