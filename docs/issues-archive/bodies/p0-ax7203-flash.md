## Goal
Sanity-verify the **newly-connected physical AX7203 unit** end-to-end through the **existing, already-proven** flow: JTAG-detect (IDCODE `0x13636093`) and re-flash the known-good `blinky_ax7203.bit` via OpenOCD + AL321, confirming DONE/LEDs blink. This is a confidence check that *this specific board* is wired and healthy before it takes on the drone-mesh bench role — **not** new enablement.

## Context
The AX7203 flow is **not** greenfield: `fpga/openxc7-synth/Makefile.200t` + `ax7203_al321.cfg`, `specs/fpga/constraints/ax7203.xdc`, `fpga/vivado/blinky_ax7203.v`, and 40+ `ax7203-*` CI workflows already synth+flash it, with a confirmed blinky (`fpga/experience/2026-06-24-ax7203-blinky-openxc7.trinity.md`) and 39 bit-exact cells measured on silicon (EPIC #199, 2026-07-01). What is *new* is that a physical unit was just connected for the mesh track — so we JTAG-detect and re-flash the existing bitstream on **this** unit to rule out cabling / power / dead-TDO faults (see the `TDO stuck at 0` / IDCODE `0x00000000` failure in `fpga/HARDWARE_TEST_RESULTS.md`).

Board: **ALINX AX7203 = XC7A200T-FBG484-2**, IDCODE **`0x13636093`** (rev 1; raw `0x03636093`), flashed over its **AL321 (FT2232H) USB-JTAG via OpenOCD** (the proven path — `ax7203_al321.cfg`), clock is **DIFF_SSTL15** on R4 (NOT LVDS — LVDS blocked DONE). Its mesh role is the bench compute + video-radio + 2×GbE node.

## Tasks
- [ ] Connect the AX7203 AL321 cable; `openFPGALoader --detect` (or OpenOCD `scan_chain`) reports IDCODE **`0x13636093`**, NOT `0x0` / `0xFFFE` (rule out the dead-TDO / CPLD fault from `fpga/HARDWARE_TEST_RESULTS.md`).
- [ ] Re-flash the existing known-good `blinky_ax7203.bit` (rebuild via `make -f fpga/openxc7-synth/Makefile.200t` if needed) through OpenOCD + `ax7203_al321.cfg` — reuse the existing bitstream/XDC, author nothing new.
- [ ] Verify with **video capture + per-frame brightness analysis** (a single photo is insufficient per `fpga/COMMON_PITFALLS.md`); confirm DONE is lit and LEDs toggle at the designed rate.
- [ ] Append an entry to `fpga/FLASH_HISTORY.md`: date, board = AX7203 unit, measured IDCODE `0x13636093`, tool = OpenOCD + AL321, bitstream, verification = video, result.

## Acceptance criteria
- IDCODE reads **`0x13636093`** on the connected AX7203 (explicitly not `0x0`/`0xFFFE`).
- The existing `blinky_ax7203.bit` flashes with no error over OpenOCD/AL321.
- Video + frame-brightness analysis confirms DONE + LED blink at the designed rate.
- `fpga/FLASH_HISTORY.md` updated with the real measured values for this unit.

## Dependencies
- `blocked_by`: none — reuses the existing proven AX7203 flow. Runs in parallel with the Mini P0 track.
- Related: the Mini bring-up (`p0-mini-boot`) and toolchain issue (`p0-toolchain`) are the *new* P0 work; this issue is a quick health check of the already-working AX7203.

φ² + φ⁻² = 3
