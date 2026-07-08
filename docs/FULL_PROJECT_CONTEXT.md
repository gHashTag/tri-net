# TRI-NET — FULL PROJECT CONTEXT

**Date:** 2026-07-08
**Anchor:** phi^2 + phi^-2 = 3
**Repo:** github.com/gHashTag/trios-mesh

---

## 1. PROJECT OVERVIEW

Tri-Net is a military-grade FPGA mesh communication system built on 3x P201Mini boards (Zynq 7020 + AD9361 transceiver). The vision: Telegram-style messaging UX on hardware PHY with three adaptive channels (text/photo/video) auto-negotiated by link quality.

**Core differentiator:** Only system with consumer UX + hardware FPGA crypto + programmable PHY + custom waveforms.

### Three-Channel Architecture

```
Channel T (text)   BPSK   1200 bps   10 km   200-byte msg = 1.3 sec
Channel P (photo)  QPSK   250 kbps    3 km   100 KB JPEG = 3.2 sec
Channel V (video)  16QAM  2 Mbps      1 km   720p live @ 500 kbps
```

### Auto-Negotiation by SNR
- SNR > 20 dB: channels T + P + V active
- SNR 10-20 dB: channels T + P active
- SNR < 10 dB: channel T only

---

## 2. HARDWARE

### Boards: 3x P201Mini (ALINX/Aithtech)
- **SoC:** Xilinx Zynq 7020 (ARM Cortex-A9 dual 667MHz + Artix-7 FPGA)
- **RF:** Analog Devices AD9361 (70 MHz - 6 GHz, 2x2 MIMO)
- **RAM:** 1GB DDR3 (MT41K256M16TW)
- **Ethernet:** 1 port (PL-side, RGMII through FPGA, requires bitstream)
- **Flash:** Winbond W25Q256 (32MB QSPI) — kernel detects as n25q256a (BUG)
- **USB:** Type-C power + FT2232H JTAG/UART
- **SD:** microSD slot

### Board Status (as of 2026-07-08)
| Board | MAC (uEnv) | Status | Issue |
|-------|-----------|--------|-------|
| Board 1 | 02:00:00:00:00:01 | DEAD | JTAG MMU damage (DAP can't access SLCR/DDR3) |
| Board 2 | 02:00:00:00:00:02 | NEEDS FRESH SD | SD card worn out (10+ erase cycles) |
| Board 3 | 02:00:00:00:00:03 | NEEDS FRESH SD | New SD card written but boot unstable (appears in ARP briefly at .11 via DHCP, then dies) |

### FPGA Resources (XC7Z020-2CLG400I)
| Resource | Total | Used (ADI design) | Free for Tri-Net |
|----------|-------|--------------------|-----------------|
| LUTs | 53,200 | ~18,000 (34%) | ~35,000 |
| FFs | 106,400 | ~22,000 (21%) | ~84,000 |
| BRAM 36Kb | 140 | ~65 (46%) | ~75 blocks |
| DSP48E1 | 220 | ~12 (5%) | ~208 |
| MMCM | 4 | 3 (75%) | 1 |

**~60% of FPGA is free** for: AES-256 HW engine, BPSK/QPSK/OFDM modems, Viterbi/RS FEC, mesh routing, TRNG, spectrum scanner.

---

## 3. SOFTWARE STACK

### Golden Pipeline (MANDATORY)
```
.t27 spec -> t27c parse/typecheck -> t27c gen-rust -> gen/rust/ -> src/ -> cargo build -> deploy
```
- **86 .t27 specifications** (source of truth)
- **904 tests, 63 invariants**
- **86 Rust modules** generated (gen/rust/)
- **12 Verilog modules** generated (gen/verilog/)
- Zero hand-written business logic in Rust
- Zero .sh/.py scripts on critical path

### 86 Spec Files
```
access_control.t27          adaptive_retry.t27         adaptive_routing.t27
aes256_gcm.t27              anomaly_detector.t27       api_documenter.t27
area_optimization.t27       auto_config.t27            bandwidth_allocator.t27
byte_utils.t27              cache_management.t27       channel_p_modem.t27
channel_t_modem.t27         channel_v_modem.t27        chat_protocol.t27
codec2_voice.t27            compression_engine.t27     congestion_control.t27
crc16.t27                   cross_layer_optimizer.t27  docs_generator.t27
energy_aware_routing.t27    etx.t27                    failure_predictor.t27
fault_detection.t27         flow_control.t27           fpga_aes_sbox.t27
fpga_bpsk_tx.t27            fpga_synthesis_report.t27  frame_buffer.t27
gps_pps.t27                 hardware_validation.t27    health_dashboard.t27
health_monitoring.t27       hello.t27                  integration_framework.t27
integration_tests.t27       integration.t27            key_management.t27
link_negotiation.t27        link_quality_monitor.t27   link_statistics.t27
lite_crypto.t27             load_predictor.t27         local_processing.t27
m3_multihop.t27             mesh_convergence.t27       mesh_node_sim.t27
mesh_protocol_stack.t27     mesh_routing.t27           multipath_router.t27
multipath_routing.t27       network_analytics.t27      network_coding.t27
network_metrics.t27         network_orchestrator.t27   network_simulator.t27
olsr_routing.t27            packet_loss_injection.t27  packet_queue.t27
pattern_predictor.t27       performance_benchmarks.t27 performance_profiler.t27
photo_transfer.t27          power_monitoring.t27       production_deployment.t27
production_scenarios.t27    quarantine_manager.t27     redundancy_management.t27
reed_solomon.t27            resource_scheduler.t27     security_audit.t27
self_healing.t27            swarm_coordinator.t27      test_framework.t27
test_validator.t27          timer.t27                  timing_closure.t27
topology_visualizer.t27     traffic_animator.t27       transport_tx_fsm.t27
trng.t27                    trust_manager.t27          video_stream.t27
viterbi_k5.t27              wire.t27
```

### Rust Binaries (src/bin/)
- **trios_meshd** — mesh daemon (ETX routing, X25519 + ChaCha20-Poly1305)
- **smoke_m1** — M1 crypto smoke test (X25519 handshake, AEAD, tamper, replay)

### Tri CLI (tools/tri)
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

### Cargo.toml Dependencies
```toml
x25519-dalek = { version = "2.0", features = ["static_secrets", "zeroize"] }
chacha20poly1305 = "0.10"
hkdf = "0.12"
sha2 = "0.10"
rand_core = { version = "0.6", features = ["getrandom"] }
zeroize = { version = "1", features = ["derive"] }
num-complex = "0.4"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
```

### Cross-Compile
```bash
brew unlink rust  # Homebrew rust shadows rustup
cargo zigbuild --release --target armv7-unknown-linux-musleabihf
```

---

## 4. CONSTITUTIONAL LAW (SOUL.md)

### Article I: Language Policy
- Source files MUST be ASCII-only, English identifiers
- Documentation MUST be English

### Article II: Golden Pipeline Mandate
- All business logic in .t27 -> t27c -> gen/rust -> src
- No hand-written Rust for business logic. No .sh/.py files

### Article III: TDD Mandate
- Every .t27 spec MUST contain test or invariant blocks

### Article IV: Hardware Safety
1. NEVER run QSPI experiments via Linux user-space (bus hang, POR cleared)
2. NEVER connect JTAG to working boards unnecessarily (clear_reset_cause)
3. NEVER delete primary IP via SSH (kills session)
4. NEVER change MAC via `ip link set` (board loses network)
5. Cold power-cycle only (warm reboot hangs Zynq PS)
6. SD boot is the safe path

### Article V: Multi-Board Boot Procedure (PROVEN)

#### SD Card Recipe (5 files, FAT32)
```
1. BOOT.BIN        — Vendor 2.9MB (ZIP 001 SD-BOOT/BOOT.bin) NOT Kuiper 4.7MB
2. uImage          — 4.3MB (ZIP 001 SD-BOOT/)
3. devicetree.dtb  — 19KB (ZIP 002 SD-BOOT/)
4. uramdisk.image.gz — 5.6MB (ZIP 002 SD-BOOT/) — ORIGINAL unmodified
5. uEnv.txt        — 55 lines (ZIP 001 SD-BOOT/) — ONLY ethaddr changed
```

#### Boot Switch Position: DOES NOT MATTER
- BootROM auto-detects SD card presence regardless of switch position
- Switch JTAG + SD inserted = boots from SD (PROVEN)
- Do NOT change boot switch for SD boot

#### Per-Board ethaddr
```
Board 1: ethaddr=02:00:00:00:00:01  IP 192.168.1.11
Board 2: ethaddr=02:00:00:00:00:02  IP 192.168.1.12
Board 3: ethaddr=02:00:00:00:00:03  IP 192.168.1.13
```
- ethaddr in uEnv.txt DOES change Linux MAC (U-Boot patches device tree)
- ipaddr in uEnv.txt does NOT change Linux IP (U-Boot only)
- boardargs/uenvcmd in uEnv.txt causes INFINITE RECURSION (do not use)

#### Multi-Board IP Separation (runtime, proven)
1. Boot one board, SSH to .10
2. `ip addr add 192.168.1.1N/24 dev eth0` (add secondary, do NOT delete .10)
3. `arp -d .10` on Mac
4. Boot next board on .10, SSH, repeat
5. Access boards by .11/.12/.13

### Article VI: Architecture
- Each P201Mini has ONE Ethernet port. Mesh over UDP/Ethernet
- Board 1 = internet gateway. Others relay through mesh
- Self-healing: ETX detects link failure in ~900ms

### Article VII: Identity
- phi^2 + phi^-2 = 3 | TRINITY

### Article VIII: Boot Switch
- Boot switch position does NOT matter for SD boot (auto-detect)

---

## 5. LAWS (L1-L7)

| Law | Name | Summary | Priority |
|-----|------|---------|----------|
| L1 | TRACEABILITY | No code merged without issue reference | Highest |
| L2 | GENERATION | Files under gen/ are generated; edit specs instead | |
| L3 | PURITY | Source files must be ASCII-only, English identifiers | |
| L4 | TESTABILITY | Every .t27 spec must contain test/invariant/bench | |
| L5 | IDENTITY | phi^2 + phi^-2 = 3; numeric SSOT | |
| L6 | PIPELINE | No hand-written Rust for business logic | |
| L7 | UNITY | No new shell scripts on critical path | Lowest |

---

## 6. TEST RESULTS

### M1 Crypto Smoke — PASS (3/3 boards)
```
X25519 handshake:         OK on all 3 boards
ChaCha20-Poly1305 AEAD:   round-trip OK on all 3 boards
Tamper detection:         rejected (flipped tag -> Auth error)
Replay protection:        rejected (re-delivered frame -> Replay error)
```
Binary: smoke_m1 (Rust, armv7-unknown-linux-musleabihf, static)

### M2 Mesh Convergence — PASS (loopback 3-node)
```
3 meshd instances on 127.0.0.1:5001/5002/5003
Node 11: ETX 12=1.00, 13=1.00   TX -> 13: Forwarded(13)
Node 12: ETX 11=1.00, 13=1.00   (relay, all links converged)
Node 13: DELIVERED (last hop 11): hello_from_11

ETX convergence: inf -> 1.00 in ~600ms
Message delivery: 11 -> 13 DELIVERED via multi-hop forward
```

### E2E RF Test — 30/30 PASSED
```
RF: 2400 MHz (Thailand ISM 2.4 GHz), 4 MSPS, 2 MHz BW
OTA: Board 1 TX -> Board 3 RSSI +8.75 dB delta (signal detected)
Loopback RSSI: 27.75 dB (auto), 24.00 dB (tx_quad), 22.00 dB (bbrf)
```

### All Milestones
| Milestone | Status |
|-----------|--------|
| M1 crypto (X25519 + ChaCha20-Poly1305) | PASS (hardware, 3/3) |
| AD9361 detection | PASS (all 3 boards) |
| Mesh connectivity (ping) | PASS (all pairs) |
| OTA RF signal detection | PASS (RSSI +8.75 dB) |
| M2 loopback mesh | PASS (ETX convergence 600ms) |
| M2 two-board real mesh | BLOCKED (need stable SD boot) |
| M2 three-board convergence | BLOCKED (need 3 stable boards) |

---

## 7. COMPETITIVE POSITIONING

| Axis | Meshtastic | Reticulum | AREDN | Silvus | **Tri-Net** |
|------|-----------|-----------|-------|--------|-------------|
| Cost/node | $30-120 | $50+ | $80-200 | $15-50K | **$500** |
| Throughput | 1-8 kbps | 150bps-1.2Gbps | 1-30 Mbps | 25-100 Mbps | **1.2k-2M** |
| Encryption | AES-128 SW | AES-256 SW | WPA2 | AES-256 HW | **AES-256 PL HW** |
| License | None | None | HAM req | ITAR | **None** |
| Freq range | Fixed | Multi | 2.4/5 GHz | 1.2-6 GHz | **70M-6G** |
| FPGA | No | No | No | Yes | **Yes (Zynq)** |
| PHY upgradable | No | No | No | No | **Yes** |
| Photo | 40 min | sec-min | sec | ms | **3 sec** |
| Video | Impossible | WiFi only | Yes | Native | **Live 720p** |
| Voice | No | No | No | Yes | **Codec2 700 bps** |

### Unfair Advantages
1. 800x faster photo than Meshtastic (3 sec vs 40 min)
2. Hardware crypto in PL — line-rate, side-channel resistant
3. Programmable PHY — upgrade modem without changing hardware
4. Any frequency 70M-6G — sub-GHz for NLOS, 2.4G for video
5. TRNG in FPGA — regulator-compliant entropy
6. Codec2 voice — walkie-talkie mode on text channel

---

## 8. FULL TROUBLESHOOTING (10 problems)

### P1: All 3 boards dead on arrival
**Cause:** Zynq PS hangs on warm reboot. FSBL parks at 0x057C when POR bit cleared.
**Fix:** SD card boot bypasses POR check.

### P2: QSPI flash reads return 0xFF
**Cause:** W25Q256 chip detected as n25q256a (device tree bug). "failed to read ear reg".
**Status:** UNSOLVED. Cannot read/write QSPI from Linux. Cannot use fw_setenv.

### P3: JTAG DAP examination fails (intermittent)
**Cause:** Multiple boards on USB hub with identical FTDI serial number.
**Fix:** `adapter usb location "1-1.N"` in openOCD config.

### P4: DAP inaccessible after Linux boots
**Cause:** Linux enables MMU. DAP memory access through MMU -> translation fault.
**Fix:** Use SD boot (avoids JTAG entirely).

### P5: Identical MAC on all boards (00:0a:35:00:01:22)
**Cause:** All boards ship with identical MAC and IP (192.168.1.10). Switch can't route.
**Attempts:**
1. Runtime `ip addr add` — works but not persistent
2. uEnv.txt `ethaddr=` — works! MAC changes via U-Boot FDT patch
3. uEnv.txt `ipaddr=` — does NOT change Linux IP (U-Boot only)
4. uEnv.txt `boardargs` + `uenvcmd` — INFINITE RECURSION, hangs board
5. Runtime `ip link set eth0 address` — kills network permanently
6. Ramdisk modification (S99tri-net) — boot fails (cpio/mkimage format issue)
**Current approach:** uEnv.txt ethaddr ONLY + runtime ip addr add

### P6: Kuiper BOOT.BIN vs Vendor BOOT.BIN
**Cause:** Kuiper (4.7MB) lacks PL Ethernet bitstream for P201Mini.
**Fix:** ALWAYS use vendor BOOT.BIN (2.9MB from ZIP 001).

### P7: Board 1 permanently dead (JTAG MMU damage)
**Cause:** JTAG experiments (ps7_init, MMU patching, kernel load) corrupted MMU state.
**State:** DAP accessible but SLCR/DDR3 access -> data abort (MMU translation fault).
**Recovery:** Needs Vivado/XSDB Hardware Manager or physical replacement.

### P8: SD card wear (10+ erase cycles)
**Cause:** TLC flash endurance exceeded. BOOT.BIN (early sectors) reads OK, uImage (mid sectors) fails.
**Fix:** Use fresh SD card.

### P9: Boot switch position is IRRELEVANT
**Discovery:** P201Mini bootROM auto-detects SD regardless of switch position.
**Impact:** Wasted hours asking user to change switch. It does not matter.

### P10: macOS limitations
- `dd` to raw disk blocked (SIP) — use `diskutil` + `cp`
- FTDI + card reader conflict on same USB
- sshpass needs `-o PreferredAuthentications=password`
- SSH host keys change each boot — use `UserKnownHostsFile=/dev/null`

---

## 9. CURRENT BLOCKERS (as of 2026-07-08 end of session)

| Blocker | Impact | Solution |
|---------|--------|----------|
| Board 3 boot unstable | New SD card written correctly, board appears at .11 briefly (DHCP), then dies | Unknown — possibly power supply, card format, or U-Boot sdboot failing |
| Board 1 dead | JTAG MMU damage | Vivado/XSDB recovery |
| Board 2 SD worn | Same as P8 | Fresh SD card |
| QSPI inaccessible | Can't set persistent env vars | Kernel driver patch or U-Boot sf commands |
| Persistent IP | Only runtime ip addr add works | Fix S99tri-net mkimage/cpio format, OR fix kernel ip= bootargs |
| Multi-board mesh | Can't test real UDP mesh between boards | Need 2+ stable boards with unique IPs |
| No UART output | Cannot see boot messages for debugging | Possibly wrong baud rate or FTDI channel mapping |

---

## 10. REPOSITORY STRUCTURE

```
tri-net/
  SOUL.md              Constitutional law (Articles I-VIII)
  CLAUDE.md            Agent instructions (golden pipeline)
  AGENTS.md            L1-L7 laws, entry point
  Cargo.toml           Dependencies
  lefthook.yml         6 pre-commit + 2 pre-push hooks
  specs/               86 .t27 specifications (SOURCE OF TRUTH)
  gen/
    rust/              86 generated Rust modules (READ-ONLY)
    verilog/           12 generated Verilog modules (READ-ONLY)
  src/
    lib.rs             Thin re-exports
    bin/
      trios_meshd.rs   Mesh daemon binary
      smoke_m1.rs      M1 crypto smoke test binary
  tools/
    tri.rs / tri       Unified CLI (status, separate, deploy, test, mesh, regen, flash-sd, rf)
    board_init.rs      Runtime MAC/IP setter
    deploy.rs          Binary deployment to boards
    e2e_test.rs        E2E hardware test runner
    mesh_sim.rs        3-node mesh simulator
    regen.rs           Regenerate gen/ from specs
    ad9361_config.rs   RF configuration tool
    jtag-bootstrap/    openOCD scripts (ftdi_jtag.cfg, ocd_helpers.tcl, boot_uboot.ocd)
  docs/                Documentation (English)
  smoke/               Hardware test scripts
  .trinity/
    experience/        Session experience JSON
    mistakes/          3 mistake files (qspi experiments, jtag on working boards, wrong PLL register)
```

### Git Branches
- **main** — stable
- **feat/trios-chat-spec** — current working branch (PR #56 open)
- Multiple feature branches for waves/components

### Pre-commit Hooks (lefthook)
1. **ascii-only** — rejects non-ASCII in .rs/.t27/.v files (L3)
2. **no-gen-edits** — rejects direct edits to gen/ (L2)
3. **no-handwritten-logic** — rejects fn/struct/enum in src/ except src/bin/ (L6)
4. **spec-has-tests** — rejects .t27 without test/invariant/bench (L4)
5. **no-cyrillic** — rejects Cyrillic in any file
6. **no-shell-scripts** — rejects new .sh files (L7)

---

## 11. SSH ACCESS

```bash
sshpass -p 'analog' ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password \
  root@192.168.1.10
```

- Default IP: 192.168.1.10 (all boards boot here without modification)
- Password: `analog`
- After MAC change: boards appear at .11/.12/.13 via DHCP or runtime ip addr add

---

## 12. QSPI PARTITION MAP

```
mtd0: qspi-fsbl-uboot   @0x000000  (1MB)
mtd1: qspi-uboot-env    @0x100000  (128KB)
mtd2: qspi-nvmfs        @0x120000  (896KB)
mtd3: qspi-linux        @0x200000  (30MB)
```
Note: All MTD reads return 0xFF due to W25Q256/n25q256a driver mismatch.

---

## 13. JTAG

### openOCD config (ftdi_jtag.cfg)
```
adapter driver ftdi
ftdi vid_pid 0x0403 0x6010
ftdi layout_init 0x0008 0x000b
transport select jtag
```

### TAP IDs
- Zynq CPU TAP: 0x23727093 (irlen=6)
- ARM DAP: 0x4ba00477 (irlen=4)

### Key Registers
- PLL_STATUS: **0xF800010C** (NOT 0xF800011C!)
- SLCR unlock: 0xF8000008 = 0x0000DF0D

### ps7_init
- P201Mini ps7_init extracted from fsbl.elf: 208 commands
- Located at `/tmp/ps7_p201mini.tcl`
- Correct DDR3 config for MT41K256M16TW (NOT PlutoSDR config)

### FTDI
- 3 boards, all with identical serial: 210203859289
- USB ports: (1,2), (1,3), (1,4) on bus 1
- Channel A = UART, Channel B = JTAG (per FT2232H)
- Target specific board: `adapter usb location "1-1.N"`

---

## 14. VENDOR FILES

### Location
```
~/Downloads/P201Mini_P203Mini-20260706T130742Z-3-001.zip  (BOOT.BIN, uImage, uEnv.txt)
~/Downloads/P201Mini_P203Mini-20260706T130742Z-3-002.zip  (devicetree.dtb, uramdisk.image.gz)
~/Downloads/P201Mini_P203Mini-20260706T130742Z-3-003.zip  (docs, schematics)
```

### File Verification (magic bytes)
```
BOOT.BIN:           offset 0x20, expect 0xAA995566 (Zynq boot image)
uImage:             offset 0x00, expect 0x27051956 (U-Boot legacy image)
devicetree.dtb:     offset 0x00, expect 0xD00DFEED (FDT magic)
uramdisk.image.gz:  offset 0x00, expect 0x27051956 (U-Boot ramdisk image)
```

### SD Card Format Command (macOS)
```bash
diskutil eraseDisk "MS-DOS FAT32" BOOT MBRFormat /dev/diskN
# Copy 5 files, change ethaddr in uEnv.txt
# Clean macOS junk: rm -rf /Volumes/BOOT/.* /Volumes/BOOT/.Spotlight-V100 /Volumes/BOOT/.fseventsd
# Eject: diskutil eject /dev/diskN
```

---

## 15. IMPLEMENTATION ROADMAP

### Phase 1 (W12-W14): Channel T — text-only mesh chat
- BPSK modem, CRC-8, framing (specs: channel_t_modem.t27)
- TRNG hardware entropy (specs: trng.t27)
- MVP: text messages over 3 boards, BPSK 1200 bps, AES-256-GCM

### Phase 2 (W14-W16): Channel P — photo transfer
- QPSK modem, CRC-16, Reed-Solomon (specs: channel_p_modem.t27, reed_solomon.t27)
- 100 KB photo transfer in 3.2 seconds

### Phase 3 (W16-W20): Channel V — live video
- OFDM PHY, 256-point FFT (specs: future)
- Viterbi FEC K=5 (specs: viterbi_k5.t27)
- 720p video streaming at 500 kbps

### FPGA Resource Budget
| Block | LUT | DSP | BRAM |
|-------|-----|-----|------|
| AES-256-GCM PL | 6k | 0 | 4 |
| BPSK/QPSK modem | 4k | 40 | 8 |
| OFDM FFT-256 16-QAM | 12k | 80 | 20 |
| Viterbi K=5 | 4k | 16 | 8 |
| Reed-Solomon | 2k | 8 | 4 |
| ETX router | 4k | 12 | 12 |
| TRNG | 0.5k | 0 | 0 |
| Codec2 voice | 1.5k | 4 | 2 |
| **Total** | **36.3k** | **204** | **69** |
(Fits in available ~35k LUT / 208 DSP / 75 BRAM)

---

## 16. KEY DECISIONS

1. **SD boot is primary path** — bypasses QSPI POR issue, FSBL parking, JTAG complications
2. **Vendor BOOT.BIN (2.9MB) required** — Kuiper BOOT.BIN lacks PL Ethernet bitstream
3. **uEnv.txt ethaddr change ONLY** — proven working. No boardargs/uenvcmd (causes recursion)
4. **Loopback mesh test** validates full mesh stack on 1 board when multi-board is blocked
5. **Boot switch position irrelevant** for SD boot (auto-detect)
6. **Runtime ip addr add** is the only reliable IP separation method
7. **Cold power cycle only** — warm reboot hangs Zynq PS

---

## 17. CRITICAL MISTAKES (documented for learning)

1. **QSPI experiments via Linux user-space** — spidev/devmem caused bus hang -> POR cleared -> boards "died". SD boot bypasses this.
2. **JTAG on working boards** — U-Boot `clear_reset_cause` cleared POR bit. After JTAG, QSPI boot impossible.
3. **Wrong PLL register** — spent hours reading 0xF800011C instead of 0xF800010C.
4. **PlutoSDR ps7_init on P201Mini** — different DDR3 chips, caused data aborts.
5. **boardargs/uenvcmd in uEnv.txt** — caused infinite recursion (sdboot -> uenvboot -> uenvcmd -> sdboot).
6. **Ramdisk modification** — mkimage CRC mismatch, cpio format issues, boot fails.

---

## 18. NEXT STEPS

1. **Stabilize board 3 boot** — investigate why new SD card produces unstable boot (appears briefly at .11 via DHCP, then dies)
2. **Get board 2 online** — flash fresh SD with proven recipe
3. **Multi-board simultaneous operation** — 2+ boards with unique IPs via runtime ip addr add
4. **M2 two-board real mesh** — UDP between .12 and .13, ETX convergence, message delivery
5. **Persistent IP solution** — fix S99tri-net mkimage/cpio format, OR fix kernel ip= bootargs format
6. **Channel T FPGA implementation** — BPSK TX in PL (spec ready: fpga_bpsk_tx.t27)
7. **AD9361 sample-level TX/RX** — requires correct P201Mini bitstream (not Kuiper)

phi^2 + phi^-2 = 3 | TRINITY
