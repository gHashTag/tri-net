Part of the TRI-NET drone-mesh track (EPIC `drone-mesh`). Documentation-only; no RTL.

## Goal
Fix three doc defects that make the repo's hardware state read dishonestly: (1) the `fpga/IDCODE.md` **100T/200T mislabel**, (2) the over-claimed single-photo "FPGA RUNNING" flash log, and (3) foreign `/Users/playra/...` paths — and add explicit NOT-COVERED banners for the greenfield tri-net radio/Zynq/mesh stack.

## Context
Now that both boards are physically connected (AX7203 `xc7a200t` bench node + P201/P203 Mini `xc7z020` flying node), the docs must state hardware truth precisely. Three problems:

**1. IDCODE.md mislabels the chip family.** `fpga/IDCODE.md` claims part-number field `0x3631` = **XC7A200T** and that "the board labeled XC7A100T is really a 200T". This is backwards vs the Xilinx 7-series IDCODEs and vs the repo's own AX7203 flow:
- `0x3631` → **XC7A100T** (IDCODE `0x13631093`, raw `0x03631093`) — this is the old **QMTech** board.
- `0x3636` → **XC7A200T** (IDCODE `0x13636093`, raw `0x03636093`) — this is the **ALINX AX7203**, per `fpga/openxc7-synth/ax7203_al321.cfg` (`# Verified: JTAG IDCODE 0x13636093 (Artix-7 XC7A200T-FBG484-2 rev 1)`, `-expected-id 0x13636093`), `fpga/experience/2026-06-24-ax7203-blinky-openxc7.trinity.md` (`JTAG IDCODE 0x13636093`), and EPIC #199.
So `0x13636093` is the **real, in-use AX7203 IDCODE** (27 code references) — it must NOT be removed. The QMTech board's `0x13631093` (41 references) is genuinely an XC7A100T.

**2. Over-claimed flash log.** `fpga/FLASH_HISTORY.md` Attempt #001 (2026-03) is marked ✅ SUCCESS / "FPGA RUNNING!" on the QMTech `xc7a100t` board, but its only evidence is a single iPhone photo — which `fpga/COMMON_PITFALLS.md` ("Single Photo for Blinking LED") explicitly calls insufficient, and `fpga/openxc7-synth/FLASH_HISTORY.md` contradicts with "flash pending / synthesis only". (Note: this is separate from the AX7203, which IS hardware-verified via OpenOCD/AL321 + #199 — do not downgrade that.)

**3. Foreign paths.** Operational commands in these logs hardcode `/Users/playra/trinity-w1/...` + an `/etc/sudoers.d/fpga_tools` NOPASSWD assumption — neither exists here (user `ssdm4`, repo `/Users/ssdm4/Desktop/PROJECTS/CLAUDE/trinity`).

**4. Silent gaps.** The tri-net radio/Zynq/mesh stack has zero doc coverage, so its absence reads as "done".

## Tasks
- [ ] **IDCODE.md fix:** correct the decode table — `0x3631`=XC7A100T (`0x13631093`, the QMTech board), `0x3636`=XC7A200T (`0x13636093`, the ALINX AX7203). Remove the "board labeled 100T is really a 200T" claim. Keep both IDCODEs; state which physical board each belongs to.
- [ ] **FLASH_HISTORY reconciliation:** downgrade the QMTech Attempt #001 from "✅ SUCCESS / FPGA RUNNING" to "⚠️ WEAK — single iPhone photo, unverified per `COMMON_PITFALLS.md` (needs video-frame-brightness or UART loopback)"; mark `fpga/openxc7-synth/FLASH_HISTORY.md` as superseded to remove the date/status contradiction. Add a header row for the AX7203 as the **verified** flow (OpenOCD/AL321, IDCODE `0x13636093`, #199).
- [ ] **Foreign paths:** rewrite all `/Users/playra/trinity-w1/...` and drop the `/etc/sudoers.d/fpga_tools` NOPASSWD assumption → repo-relative / `/Users/ssdm4/Desktop/PROJECTS/CLAUDE/trinity/fpga/...`.
- [ ] **NOT-COVERED banners** (greenfield / unproven on hardware, mark `-sim` where applicable): Zynq-7020 PS boot (Vivado/PetaLinux/FSBL/bootgen — openxc7 does NOT produce a Zynq boot image); AD9361/AD9363 SDR bring-up (libiio/no-OS, 5.8 GHz OFDM PHY); external PA+LNA @5.8 GHz (onboard Mini PA only 10–15 dBm); `trios-mesh` (ETX + X25519 + ChaCha20-Poly1305, **sim-only, no on-disk code, no repo**).

## Acceptance criteria
- [ ] `grep -rn "/Users/playra" fpga/` → **0 matches**.
- [ ] `fpga/IDCODE.md` states `0x3631`/`0x13631093`=XC7A100T (QMTech) and `0x3636`/`0x13636093`=XC7A200T (AX7203), consistent with `ax7203_al321.cfg`. The 27 existing `0x13636093` references remain valid (NOT deleted).
- [ ] Reading `fpga/FLASH_HISTORY.md` + `fpga/openxc7-synth/FLASH_HISTORY.md` gives ONE consistent answer: QMTech #001 = weak/unverified; AX7203 = verified; Mini/Zynq = never flashed.
- [ ] NOT-COVERED banners for Zynq boot, AD9361 SDR, external PA+LNA, and `trios-mesh` are present, each marked greenfield / `-sim`.

## Dependencies
- `blocked_by`: none (but the `drone-mesh` label must exist first).
- Related: `skill-fix-fpga-synth` (same foreign-path defect class); feeds the Mini P0 bring-up (honest FLASH_HISTORY to write into).

φ² + φ⁻² = 3
