**Goal:** First bring-up of the flying-node Zynq-7020 (P201/P203 Mini): boot dual Cortex-A9 ARM-Linux from SD, confirm serial console, and confirm AD9361 + onboard GPS + PPS/10MHz lock.

## Context

Honest status (report v2.2): the Mini has **NEVER** been flashed, there is **no** Zynq flow in this repo, and the whole drone-mesh stack is sim-only. This issue is unblocked **now** that the FPGA hardware is physically connected — it is the first real bring-up of the *flying* MVP node.

Board: **P201/P203 Mini = Xilinx Zynq-7020 (XC7Z020, dual Cortex-A9 + 85K-LC PL)** + **AD9361** SDR transceiver (NOT AD9363 — AD9363 caps at 3.8 GHz, we need 5.8 GHz), 1x GbE, onboard GPS, PPS/10MHz input. 85×50 mm, 5V/1A, light enough to fly. Onboard PA is only 10–15 dBm (external PA+LNA @5.8GHz is a separate P1 concern, out of scope here).

Repo reality: `fpga/` targets **only** the QMTech xc7a100tfgg676 (openXC7 + Platform Cable USB II). There is **zero** Zynq support — no xc7z020 chipdb, no board def, no XDC, no IDCODE entry, no PS/FSBL/boot.bin path. openXC7/prjxray-db is artix7-only, so the PL is likely not synthesizable by the existing Docker flow. **Vivado/PetaLinux fallback is acceptable for PS boot**; PL bitstream is scoped separately from PS boot in this issue.

## Tasks

- [ ] Identify the Mini's JTAG/USB interface (onboard vs external header); run `openFPGALoader --detect` and record the **real IDCODE** for xc7z020 (Xilinx device id `0x03727093`; the JTAG read may carry a version nibble — record the actual value) — rule out a dead-TDO / stuck-at-0 fault (cf. `fpga/HARDWARE_TEST_RESULTS.md`)
- [ ] Write a reference SD image (a Zynq-7020 PetaLinux/Debian image, or Vivado+PetaLinux `boot.bin` = FSBL + u-boot + kernel + devicetree)
- [ ] Boot dual Cortex-A9 ARM-Linux from SD; confirm **serial console over USB-C** (record `uname -a`, `/proc/cpuinfo` showing 2x Cortex-A9)
- [ ] Confirm **AD9361** enumerates via `iio` — `iio_info` / `ls /sys/bus/iio/devices` shows `ad9361-phy`; verify it is AD9361 (2-rx/2-tx, up to 6 GHz), **not** AD9363
- [ ] Confirm **onboard GPS** produces NMEA fix and **PPS + 10MHz** reference lock (e.g. `gpsmon` / `ppstest /dev/pps0`)
- [ ] Record first xc7z020 IDCODE detect + boot result in `fpga/FLASH_HISTORY.md` (new Zynq/Mini entry; note this is the first-ever Mini detection)
- [ ] Note PL-bitstream synthesis for xc7z020 as **out of scope / separate issue** (no chipdb today; Vivado or a future xc7z020 prjxray-db)

## Acceptance criteria

- `openFPGALoader --detect` on the Mini reports a valid xc7z020 IDCODE (`0x03727093` device id, version nibble as read), NOT `0x00000000`
- Serial console over USB-C reaches a Linux shell; `nproc` == 2, ARM Cortex-A9 confirmed in `/proc/cpuinfo`
- `iio_info` lists `ad9361-phy` and the device reports AD9361 (5.8 GHz reachable), not AD9363
- GPS reports a position fix (NMEA `$GPGGA`) and PPS pulses are observed on `/dev/pps0`; 10MHz ref lock confirmed
- New `fpga/FLASH_HISTORY.md` entry committed with the above evidence

## Dependencies

- **blocked_by:** `p0-toolchain` — *feat(fpga): stand up openFPGALoader (gHashTag fork) + openXC7 toolchain for real boards* (need `openFPGALoader` working before JTAG detect)

---

phi^2 + phi^-2 = 3