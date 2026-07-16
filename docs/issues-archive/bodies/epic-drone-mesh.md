> **NOTE**: this EPIC uses a new `drone-mesh` label (`gh label create drone-mesh --repo gHashTag/trinity-fpga -c 1FA8A0 -d "TRI-NET self-organizing relay-drone + fixed-node internet mesh"`), kept SEPARATE from the GoldenFloat/fpga-matrix EPIC #199 and decode-HW #200–#206.

## Goal
Umbrella epic for the TRI-NET self-organizing relay-drone + fixed-node internet mesh ("Starlink without satellites"):
**P0** real toolchain bring-up + first flash on the *new* board (Zynq Mini) → **P1** 5.8 GHz OFDM radio-PHY + 2-hop encrypted IP-mesh on the bench → **P2 DEMO GATE** = 3-node triangle sharing ONE uplink with self-healing re-route.

## Context
**Why now:** the user has PHYSICALLY CONNECTED both boards, which unblocks P0.

**Honest status (report v2.2, single source of truth):**
- **ALINX AX7203** (`xc7a200tfbg484-2`, IDCODE `0x13636093`) — **ALREADY hardware-proven; reuse, do NOT re-author.** The openxc7 flow (Yosys → chipdb → nextpnr-xilinx → fasm2frames → xc7frames2bit) is hardware-verified for this board: `fpga/openxc7-synth/Makefile.200t`, `fpga/openxc7-synth/ax7203_al321.cfg` (OpenOCD + AL321 FT2232H, `-expected-id 0x13636093`), `specs/fpga/constraints/ax7203.xdc`, `fpga/vivado/blinky_ax7203.v`, 40+ `ax7203-*` CI workflows, blinky confirmed in `fpga/experience/2026-06-24-ax7203-blinky-openxc7.trinity.md` (DONE lit, LEDs blink). EPIC #199 reports 39 bit-exact cells measured on AX7203 silicon (2026-07-01). Its mesh role is bench compute + video-radio (HDMI-in) + 2×GbE — the **radio/SDR/mesh application on top is the new work, not the flash flow.**
- **P201/P203 Mini** (Zynq-7020 `xc7z020`, dual Cortex-A9 + AD9361/AD9363 SDR, 1× GbE, onboard GPS + PPS/10 MHz, 85×50 mm, 5V/1A) — **GENUINELY greenfield: never flashed, ZERO toolchain.** No `xc7z020` board def / chipdb / IDCODE / PS-boot path exists (`grep xc7z020 fpga/` = nothing). The Artix-7 openxc7 flow does **not** transfer to Zynq unchanged; PS (FSBL/BOOT.BIN) is scoped separately from the PL bitstream. Onboard PA only 10–15 dBm → needs external PA+LNA @5.8 GHz for range. **This board is the P0 critical path.**
- **`trios-mesh`** (ETX routing + X25519 + ChaCha20-Poly1305) passes unit tests **in simulation ONLY** — never on real hardware, and does not exist as a repo or on disk anywhere. Must be built from scratch.

Video-radio is DUAL PURPOSE: one 5.8 GHz OFDM radio carries video + telemetry + MAVLink-compatible drone C2, with C2 on a low-latency QoS class.

**Cannot be vibe-coded (hardware/physics-gated):** RF link budget, AD9361 5.8 GHz reach (AD9361 required — AD9363 caps at 3.8 GHz), OFDM PHY, and self-healing convergence pass or fail on the bench, not in review.

## Child issues (P0 → P1 → P2)
- [ ] **chore(repo):** create the `drone-mesh` label
- [ ] **fix(skill):** correct `fpga-synth` SKILL.md path + board target
- [ ] **docs(skill):** create the on-disk `tri-net` skill (honest Phase-0 status)
- [ ] **docs(fpga):** reconcile over-claimed FLASH_HISTORY + fix the IDCODE.md 100T/200T mislabel
- [ ] **chore(fpga):** de-hardcode `AUTO_FLASH.sh` foreign paths + parameterize cable
- [ ] **feat(fpga) P0:** Zynq-7020 Mini toolchain bring-up + adopt proven AX7203 flow as mesh baseline
- [ ] **feat(fpga) P0:** sanity-verify the newly-connected AX7203 unit via the existing OpenOCD/AL321 flow
- [ ] **feat(fpga) P0:** boot ARM-Linux on the Mini + confirm AD9361 / GPS / PPS
- [ ] **feat(fpga) P1:** AD9361 5.8 GHz TX/RX + OFDM PHY (single-carrier fallback)
- [ ] **feat(mesh) P1:** scaffold `trios-mesh` repo + M1 X25519/ChaCha20 on real ARM
- [ ] **feat(mesh) P1:** M2 TUN/netdev IP-over-radio with real ETX metric
- [ ] **feat(mesh) P1 (exit gate):** M3 iperf3 over 2 hops through attenuators
- [ ] **feat(mesh) P2 (DEMO GATE):** M4 share ONE uplink across the 3-node triangle
- [ ] **feat(mesh) P2 (DEMO GATE):** M5 self-healing re-route + convergence metric

## Acceptance criteria (phase gates)
- **P0:** `openFPGALoader --detect` / OpenOCD reports `IDCODE 0x13636093` on the AX7203 (existing proven flow — sanity check of the connected unit) **and** a valid `xc7z020` IDCODE on the Mini; the Mini boots ARM-Linux from SD with AD9361 visible in `iio_info` and GPS/PPS locked; a PL blinky path exists for the Mini (or the missing-open-DB gap is documented with a Vivado fallback, not silently assumed). All logged in `fpga/FLASH_HISTORY.md`.
- **P1:** AD9361 links two Minis @5.8 GHz over attenuators; `trios-mesh` completes an X25519 handshake + ChaCha20-Poly1305 session on real ARM-Linux (not sim); a TUN device carries IP; `iperf3` shows a throughput baseline over 1 hop and a nonzero rate **over 2 hops** through the attenuator chain.
- **P2 (GO/NO-GO):** the 3-node triangle serves internet from ONE uplink to a node with no direct uplink via 2 hops; on a killed link/node, ETX re-routes and service continues with a **measured, logged convergence time**; demo video + metrics + Apache-2.0 repo + Zenodo DOI published.

## Dependencies
- `blocked_by`: none (umbrella EPIC; children block each other in P0 → P1 → P2 order).
- **Separate from** (do NOT merge/block on): #199 EPIC GoldenFloat matrix, #200–#206 decode-HW / SW-bitexact / CI.
- **Related:** trinity#588 (trinity-fpga submodule + XVC WiFi-JTAG) — orthogonal; the ESP32-XVC bridge (`firmware/xvc-esp32`) may be reused for remote flashing.

φ² + φ⁻² = 3
