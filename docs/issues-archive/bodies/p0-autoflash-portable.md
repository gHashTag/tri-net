## Goal
Make `fpga/AUTO_FLASH.sh` runnable on any checkout by replacing `/Users/playra/trinity-w1/...` with `SCRIPT_DIR`-relative paths and parameterizing the JTAG cable so it drives the AX7203 onboard FTDI + `openFPGALoader`, not only the Platform Cable USB II.

## Context
Now that the FPGA is physically connected, P0 (toolchain bring-up + first real flash) is unblocked — but the flash scripts still assume a foreign machine. `fpga/AUTO_FLASH.sh` hardcodes `/Users/playra/trinity-w1/fpga/...` for `BITFILE`, `TOOLS`, `TEST_BIN` and a `cd` (confirmed lines 8-10, 42), so it cannot run on this checkout (user `ssdm4`, repo at `/Users/ssdm4/Desktop/PROJECTS/CLAUDE/trinity`). `fpga/flash.sh` and `fpga/xvc_flash.sh` already use `SCRIPT_DIR` and are the correct template. The same `playra` foreign paths and a Platform-Cable-only workflow also leak into `fpga/JTAG_TROUBLESHOOTING.md` (lines 16/22/27/36/76) and `fpga/FLASH_HISTORY.md`, including a `playra ALL=(ALL) NOPASSWD` sudoers block (lines 82-84) that assumes a specific user.

The flash flow is also cable-locked: `AUTO_FLASH.sh` hardwires the `fxload` (`03fd:0013` → `0x0008`) + `jtag_program` ritual for the Xilinx Platform Cable USB II clone. The connected **AX7203 (xc7a200t)** uses an onboard FTDI USB-JTAG (typ. `0403:6010`), which `jtag_program` does not support — `COMMON_PITFALLS.md` directs FTDI cables to `openFPGALoader` (gHashTag fork). So the script must select the cable/tool per board. This issue is scripts + docs only — no new board defs or bitstreams (those are separate P0 issues).

## Tasks
- [ ] `fpga/AUTO_FLASH.sh`: add `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` and derive `BITFILE`/`TOOLS`/`TEST_BIN` from it (mirror `fpga/flash.sh` / `fpga/xvc_flash.sh`); remove the hardcoded `cd /Users/playra/trinity-w1/fpga/openxc7-synth`.
- [ ] Parameterize cable via a `CABLE`/`FLASH_TOOL` env var (or `--cable`): default `platform-usb-ii` = existing `fxload`+`jtag_program` path; add `ft2232`/`openfpgaloader` = `openFPGALoader --cable ft2232 --write <bit>` (no fxload, no unplug/replug). Make `BITFILE` overridable via arg/env so it is not pinned to `vsa_uart_top.bit`.
- [ ] Guard the fxload/reconnect prompt so it only runs for the Platform-Cable path (FTDI needs neither firmware upload nor reconnect).
- [ ] `fpga/JTAG_TROUBLESHOOTING.md`: rewrite `/Users/playra/trinity-w1/...` (lines 16/22/27/36/76) to `SCRIPT_DIR`-relative / `fpga/...` paths; add a short "FTDI / AX7203 → use openFPGALoader" note so the doc is no longer Platform-Cable-only.
- [ ] `fpga/FLASH_HISTORY.md`: replace `/Users/playra/trinity-w1/...` command paths and drop the `playra ALL=(ALL) NOPASSWD` sudoers block (lines 82-84) / user assumption; note sudo is only needed for the Platform-Cable USB path, not FTDI/openFPGALoader.
- [ ] `grep -rn '/Users/playra\|trinity-w1\|NOPASSWD' fpga/` returns nothing after the edits.
- [ ] Smoke-run `bash fpga/AUTO_FLASH.sh` from a fresh clone with `CABLE=openfpgaloader` and confirm it resolves paths and reaches the flash step without a hardcoded-path failure.

## Acceptance criteria
- `grep -rn '/Users/playra\|trinity-w1' fpga/AUTO_FLASH.sh fpga/JTAG_TROUBLESHOOTING.md fpga/FLASH_HISTORY.md` → 0 hits.
- `grep -rn 'NOPASSWD' fpga/` → 0 hits.
- `bash fpga/AUTO_FLASH.sh` run from an arbitrary clone path resolves `BITFILE`/`TOOLS`/`TEST_BIN` relative to the script (no absolute foreign path in output).
- `CABLE=openfpgaloader BITFILE=<blink.bit> bash fpga/AUTO_FLASH.sh` invokes `openFPGALoader` (not `fxload`/`jtag_program`) and does not prompt for a cable reconnect.
- Default (unset `CABLE`) still executes the proven `fxload` → reconnect → `jtag_program` Platform-Cable path unchanged.

## Dependencies
None — this is a standalone P0 hygiene fix and a prerequisite for the AX7203 first-flash gate (the openFPGALoader/FTDI board-bring-up issue) and shares the `playra`-path defect class with the `fpga-synth` SKILL.md fix.

phi^2 + phi^-2 = 3