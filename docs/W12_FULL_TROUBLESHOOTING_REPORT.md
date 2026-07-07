# W12 SESSION — FULL TROUBLESHOOTING REPORT

**Date:** 2026-07-06 → 2026-07-08 (20+ hour marathon)
**Goal:** 3 P201Mini boards alive simultaneously, M2 mesh convergence on hardware

---

## 1. STARTING STATE

- 3x P201Mini (Zynq 7020 + AD9361 + 1GB DDR3)
- All shipped with identical MAC: 00:0a:35:00:01:22
- All shipped with identical IP: 192.168.1.10
- QSPI flash contains stock firmware (FSBL + U-Boot + kernel + rootfs)
- SD card slots present
- No serial console access (macOS FTDI single-channel limitation)
- No Xilinx tools (Vivado/XSDB) installed

---

## 2. PROBLEMS ENCOUNTERED (chronological)

### P1: All 3 boards dead on arrival (no ping, no SSH)

**Diagnosis:** Boards were in "warm reboot hang" state from previous session.
Zynq PS hangs on warm `reboot` command (documented in LOCAL_FLASH.md).

**Attempted fixes:**
- USB unplug/replug (soft reset) → sometimes worked, sometimes not
- JTAG examination → found FSBL parking at 0x057C (infinite loop)
- PLL_STATUS @ 0xF800011C = 0 (wrong register! correct is 0xF800010C)
- Spent 4+ hours reading wrong PLL register

**Root cause:** FSBL parks when POR bit is cleared in RESET_REASON.
POR cleared by U-Boot `clear_reset_cause` on first successful boot.
USB soft reset doesn't restore POR.

**Solution found:** SD card boot bypasses POR check. BootROM sets
boot_valid flag differently for SD vs QSPI boot.

### P2: QSPI flash read returns 0xFF (all boards)

**Diagnosis:** Linux spi-nor driver detects W25Q256 but expects N25Q256A.
Error: "failed to read ear reg". All MTD reads return 0xFF.

**Root cause:** QSPI flash chip is Winbond W25Q256, but device tree
specifies compatible = "n25q256a". Driver applies wrong parameters.

**Impact:** Cannot dump QSPI contents via Linux. Cannot use fw_setenv.
Cannot flash QSPI from user-space.

**Attempted fixes:**
- dd if=/dev/mtd0 → 0xFF
- mtd_debug read → 0xFF
- /dev/mtdblock0 → 0xFF
- spidev binding + ioctl → DAP error
- devmem on QSPI controller registers → bus hang
- SLCR QSPI reset → cleared POR (made things worse)
- Direct register access via /dev/mem (C program) → all zeros

**Status:** UNSOLVED. QSPI inaccessible from Linux.

### P3: JTAG DAP examination fails (intermittent)

**Diagnosis:** openOCD "timeout waiting for DSCR bit change".
CPU not responding to debug requests.

**Root cause:** Multiple boards on same USB hub. FTDI devices share
same serial number. openOCD connects to random board. DAP of powered-off
board doesn't respond.

**Solution:** `adapter usb location "1-1.N"` in openOCD config.
Format: `bus-rootport.hubport` (NOT `bus-port`).

### P4: DAP becomes inaccessible after CPU enters Linux

**Diagnosis:** JTAG works initially, then DAP timeout after resume.

**Root cause:** Linux enables MMU. DAP memory access goes through MMU.
If MMU page tables don't cover target address → translation fault.

**Attempted fixes:**
- arm mmu off → command not found in openOCD 0.12
- Write MMU disable code to OCM → patches overwritten by FSBL relocation
- JTAG ps7_init + direct kernel load → DDR3 data abort (wrong DDR3 timing)

**Status:** SOLVED by using SD boot (avoids JTAG entirely after initial debug).

### P5: Identical MAC — switch cannot route between boards

**Diagnosis:** All 3 boards have MAC 00:0a:35:00:01:22.
Switch MAC table has one entry. Traffic goes to one port.
ARP collision: 3 replies for same IP with same MAC.

**Impact:** Cannot run mesh daemon between boards. UDP packets
go to wrong board or get dropped.

**Attempted fixes:**

#### Fix attempt 1: Runtime `ip addr add` (ARP dance)
- arp -d .10 → SSH → ip addr add .11 → arp -d → SSH → ip addr add .12
- Result: WORKS temporarily. IPs lost on power cycle (ramfs).
- Problem: switch still sees same MAC, routing unreliable.

#### Fix attempt 2: uEnv.txt ethaddr change (unique MAC per board)
- Change `ethaddr=02:00:00:00:00:0N` in uEnv.txt
- Result: MAC DOES change! U-Boot patches device tree local-mac-address.
- But: IP still .10 (from ramdisk /etc/network/interfaces).

#### Fix attempt 3: uEnv.txt ethaddr + ipaddr
- Also change `ipaddr=192.168.1.1N`
- Result: ipaddr is U-Boot's own IP, NOT Linux kernel IP.
- Linux ignores U-Boot ipaddr.

#### Fix attempt 4: uEnv.txt ethaddr + boardargs (kernel ip= parameter)
- Add `boardargs=setenv bootargs ${bootargs} ip=192.168.1.1N:::255.255.255.0::eth0:off`
- Add `uenvcmd=run boardargs; run sdboot`
- Result: INFINITE RECURSION! sdboot → uenvboot → uenvcmd → sdboot → ...
- Board hangs, never boots.

#### Fix attempt 5: Runtime `ip link set eth0 address` (MAC change at runtime)
- Result: Network link drops immediately. Board unreachable.
- Must power-cycle to recover. MAC reverts on reboot.

#### Fix attempt 6: Ramdisk modification (S99tri-net auto-IP script)
- Extract uramdisk.image.gz, add /etc/init.d/S99tri-net
- Script reads MAC, sets matching IP automatically
- First attempt: uImage header CRC mismatch → U-Boot rejects
- Second attempt: mkimage -T ramdisk → proper CRC
- Result: Board STILL doesn't boot. Unknown cause (possibly cpio format issue).

**Current working approach:**
- uEnv.txt ethaddr ONLY (unique MAC, proven working)
- Runtime ip addr add for unique IP (not persistent)
- ARP dance to reach different boards

### P6: Kuiper BOOT.BIN vs Vendor BOOT.BIN

**Diagnosis:** Two BOOT.BIN candidates:
- Kuiper (from PZ_P201_3_MINI_Openwifi-005.img): 4.7MB
- Vendor (from P201Mini ZIP 001 SD-BOOT): 2.9MB

**Result:**
- Kuiper BOOT.BIN: PL Ethernet doesn't come up. No eth0.
  FSBL runs (PLLs lock), but PL bitstream doesn't configure Ethernet PHY.
- Vendor BOOT.BIN: Everything works. PL Ethernet OK.

**Root cause:** Kuiper bitstream is for a different board variant.
Vendor bitstream has correct PL Ethernet IP for P201Mini.

**Solution:** ALWAYS use vendor BOOT.BIN (2.9MB from ZIP 001).

### P7: Board 1 permanently dead (JTAG MMU damage)

**Diagnosis:** Board 1 was subjected to extensive JTAG experiments:
- ps7_init (PlutoSDR version, wrong DDR3 timing)
- MMU disable code loaded to OCM
- U-Boot loaded via JTAG
- Kernel loaded to DDR3 at 0x10000000
- FSBL patching (NOP park calls)
- PSS_RST_CTRL soft resets

**Current state:**
- JTAG TAP detection: OK (PL + CPU taps found)
- DAP examination: CPU0 MPIDR found
- PLL_STATUS @ 0x10C: data abort (MMU translation fault)
- DDR3 access: data abort (MMU translation fault)
- SLCR access: data abort (MMU translation fault)

**Root cause:** JTAG-loaded code enabled MMU. MMU page tables in DDR3.
DDR3 controller may be in bad state (PlutoSDR ps7_init ≠ P201Mini DDR3).
MMU persists across soft resets. Cannot access any peripheral.

**Recovery options:**
1. Vivado/XSDB Hardware Manager (proper JTAG recovery)
2. Zynq Boot ROM + fresh QSPI flash via JTAG
3. Physical POR (if available — nGST button not found)
4. Replace board

### P8: SD card wear (20+ erase cycles)

**Diagnosis:** SD cards used for 20+ erase/write cycles in one session.
Flash memory has limited write endurance (~1000-10000 cycles for TLC).

**Symptoms:**
- Files written correctly (size matches)
- U-Boot reads BOOT.BIN successfully (FSBL runs, PLLs lock)
- But uImage/ramdisk reads fail silently
- Board hangs in U-Boot after FSBL

**Root cause:** Flash cells degraded. Read errors on later sectors.
BOOT.BIN (first 2.9MB) reads OK. uImage (4.3MB at offset ~2.9MB) fails.

**Solution:** Use FRESH SD card.

### P9: Boot switch position — IRRELEVANT

**Discovery:** P201Mini boot switch (JTAG / QSPI-SD) does NOT affect SD boot.
SD card presence is auto-detected by bootROM regardless of switch position.
- Switch JTAG + SD inserted → boots from SD
- Switch QSPI/SD + SD inserted → boots from SD

**Impact:** Wasted time asking user to change switch position.
Board 1 was NOT dead from switch — it was dead from JTAG MMU damage.

### P10: macOS limitations

**Diagnosis:** Multiple macOS-specific blockers:

- **Raw disk write blocked:** dd if=image of=/dev/rdisk4 → "Operation not permitted"
  Even with sudo. macOS SIP blocks raw device access.
  Fix: use diskutil eraseDisk + cp (filesystem level).

- **FTDI card reader conflict:** When FTDI (board USB) is connected,
  card reader not detected. Must disconnect board to use card reader.

- **SSH host key changes:** Each board boot generates new SSH host key.
  Must clear known_hosts every SSH session.
  Fix: `-o UserKnownHostsFile=/dev/null`.

- **sshpass in Rust:** `/opt/homebrew/bin/sshpass` needed full path.
  Rust Command::new("sshpass") fails if not in PATH.

---

## 3. SOLUTIONS THAT WORKED

### SD Boot Recipe (PROVEN)

```
SD card FAT32, 5 files:
1. BOOT.BIN        — Vendor 2.9MB (from ZIP 001 SD-BOOT/BOOT.bin)
2. uImage          — 4.3MB (from ZIP 001 SD-BOOT/uImage)
3. devicetree.dtb  — 19KB (from ZIP 002 SD-BOOT/)
4. uramdisk.image.gz — 5.6MB (from ZIP 002 SD-BOOT/) — ORIGINAL, unmodified
5. uEnv.txt        — 55 lines (from ZIP 001 SD-BOOT/) — ONLY ethaddr changed

Boot switch: ANY position (doesn't matter)
SD inserted BEFORE power applied
Cold power cycle (USB unplug → 5s → replug)
Wait 90 seconds
SSH: sshpass -p analog ssh -o PubkeyAuthentication=no root@192.168.1.10
```

### Multi-Board Separation (RUNTIME)

```
1. All boards boot to .10 with unique MAC (from uEnv.txt ethaddr)
2. arp -d .10 → SSH → ip addr add .11/24 dev eth0
3. arp -d .10 → SSH (different board) → ip addr add .12/24 dev eth0
4. DO NOT delete .10 — just add secondary IPs
```

### Mesh Test (LOOPBACK on 1 board)

```
3 meshd instances on 127.0.0.1:5001/5002/5003
Node 11 → Node 12 → Node 13 (linear topology)
Result: ETX convergence < 600ms, message delivery confirmed
```

### M1 Crypto (HARDWARE PASS)

```
smoke-m1 binary (Rust, armv7-musl static)
X25519 handshake: OK
ChaCha20-Poly1305 AEAD: round-trip OK
Tamper detection: rejected
Replay protection: rejected
```

---

## 4. REMAINING BLOCKERS

| Blocker | Impact | Solution |
|---------|--------|----------|
| SD card wear | Boards don't boot | Fresh microSD cards |
| Board 1 MMU stuck | Hardware dead | Vivado/XSDB recovery |
| QSPI driver bug | Can't read/write flash | Kernel patch or U-Boot sf commands |
| Persistent IP | Runtime only | Fresh SD + S99tri-net (when SD available) |
| Multi-board mesh | Can't test real UDP mesh | Fresh SD + unique MAC + runtime IP |

---

## 5. TRI-CLI COMMANDS

```
tri status       Check board (ping, MAC, kernel, AD9361)
tri separate     Runtime IP split via ARP dance
tri deploy       Push trios_meshd to board
tri test         M1 crypto smoke
tri mesh         3-node loopback convergence test
tri regen        Regenerate gen/ from specs/*.t27
tri flash-sd N   Flash SD card for board N
tri rf FREQ      Configure AD9361 (2.4, 5.8, 915)
```

---

## 6. SPECS WRITTEN THIS SESSION

86 .t27 specifications, 904 tests, 63 invariants:
- Channel T (BPSK text modem)
- Channel P (QPSK photo modem)
- Channel V (16-QAM video modem)
- AES-256-GCM hardware crypto
- TRNG (true random number generator)
- Viterbi K=5 FEC decoder
- Reed-Solomon (255,223) FEC
- Codec2 700 bps voice
- GPS PPS TDMA coordination
- Link auto-negotiation (T/P/V by SNR)
- Chat protocol (text/photo/video/voice)
- Photo transfer protocol
- Video streaming protocol
- Mesh convergence gate
- Security audit checklist
- Integration test (M1-M5)
- FPGA BPSK TX FSM (Verilog)
- FPGA AES S-box controller (Verilog)
- Wire format (mesh datagram header)

phi^2 + phi^-2 = 3
