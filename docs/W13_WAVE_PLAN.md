# WAVE W13: Mesh Convergence + Channel T Prototype

**Start:** 2026-07-07
**End:** 2026-07-14 (1 week)
**Anchor:** phi^2 + phi^-2 = 3

---

## Context

W12 delivered: 3 boards alive (SD boot), M1 crypto PASS on ARM, 75 specs, golden pipeline enforced.
M2 mesh blocked by identical MAC on switch. This wave removes that blocker and delivers working mesh.

---

## Deliverables

| # | Deliverable | Gate | Spec/Tool |
|---|-------------|------|-----------|
| 1 | Per-board identity (unique MAC + IP via EEPROM or SD) | 3 boards pingable simultaneously | init script |
| 2 | M2 two-board mesh convergence | ETX < inf, HELLO exchange visible | trios_meshd |
| 3 | M2 three-board triangle | All pairs reachable, multi-hop forward | trios_meshd |
| 4 | Channel T BPSK modem deploy | TX carrier detected on neighbor RSSI | channel_t_modem.t27 |
| 5 | Stock bitstream flash | RX DMA (cf-ad9361-lpc) in IIO | P201Mini FIT |

---

## Step 1: Per-Board MAC/IP

### Problem
All 3 P201Mini ship with identical MAC 00:0a:35:00:01:22. Switch can't route between them.

### Solution: SD card per-board init script
Each SD card gets a `board_init.sh`... wait, L7 (no .sh). Use Rust binary `tools/board_init`.

`board_init` reads board serial (from /proc/cpuinfo or CPU ID register), maps to MAC+IP:

```
Board serial 0x...001 -> MAC 02:00:00:00:00:01, IP 192.168.1.11
Board serial 0x...002 -> MAC 02:00:00:00:00:02, IP 192.168.1.12
Board serial 0x...003 -> MAC 02:00:00:00:00:03, IP 192.168.1.13
```

This binary runs on boot (called from rcS or uEnv.txt uenvcmd).

### Alternative: uEnv.txt per-board
U-Boot can set ethaddr per SD card. Three uEnv.txt files, three SD cards.
`uenvcmd=setenv ethaddr 02:00:00:00:00:0N; ...`

Simpler, but requires manual SD card labeling.

**Decision: uEnv.txt approach (simplest, no code needed).**

---

## Step 2: M2 Two-Board Mesh

After unique MACs, run trios_meshd on 2 boards:
- Board 1 (.11): `id 11, peer 12`
- Board 2 (.12): `id 12, peer 11`

Gate: ETX metric goes from `inf` to finite (< 10) within 5 seconds.

---

## Step 3: M2 Three-Board Triangle

Add board 3:
- Board 3 (.13): `id 13, peer 12`

Test multi-hop: Board 1 sends to Board 3 through Board 12.

Gate: message delivered (2-hop path), ETX visible for all pairs.

---

## Step 4: Channel T Deploy

Deploy BPSK modem (from specs/channel_t_modem.t27, gen/rust/channel_t_modem.rs):
1. Generate IQ samples on ARM
2. Send to AD9361 TX DMA
3. Neighbor detects carrier on RSSI

Needs stock bitstream (step 5) for DMA access. If blocked, use loopback test first.

---

## Step 5: Stock Bitstream

Replace Kuiper BOOT.BIN with P201Mini stock FIT (pzp201mini.bin):
- Stock FIT includes correct bitstream with cf-ad9361-lpc RX DMA
- Stock FIT includes correct DTB with PL Ethernet

New SD card: BOOT.BIN (Kuiper FSBL) + pzp201mini.bin (stock FIT) + uEnv.txt (FIT loader)

---

## Blocker Mitigation

| Blocker | Mitigation |
|---------|-----------|
| sshd hang on warm reboot | Cold power-cycle only |
| QSPI read driver bug (W25Q256) | Use SD boot, ignore QSPI |
| No serial console on macOS | UTM VM if needed (not blocking) |

---

## Spec Pipeline (new this wave)

```
specs/channel_t_modem.t27   EXISTS (12 tests)
specs/trng.t27              EXISTS (18 tests)
specs/aes256_gcm.t27        EXISTS (19 tests)
specs/link_negotiation.t27  EXISTS (15 tests)

NEW:
specs/mesh_convergence.t27   ETX convergence invariant
specs/board_identity.t27     Board ID -> MAC/IP mapping
```

phi^2 + phi^-2 = 3
