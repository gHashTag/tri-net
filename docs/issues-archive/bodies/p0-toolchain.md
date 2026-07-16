## Goal

Bring up the **P201/P203 Mini** (`xc7z020`) as a new toolchain target for the TRI-NET drone-mesh track, and formally adopt the **already-proven** AX7203 (`xc7a200tfbg484-2`) flow as the mesh track's ground/bench synth+flash baseline. The Mini has **never been flashed** and has **zero** toolchain support in this repo; the AX7203 is already hardware-verified and is reused as-is.

## Context

Phase 0 of the TRI-NET drone-mesh track. Both boards are physically connected right now — this unblocks the first real Mini bring-up.

**Honest status of each board:**

- **AX7203 (`xc7a200tfbg484-2`, IDCODE `0x13636093`) — ALREADY PROVEN, reuse only.** The openxc7 flow (Yosys → chipdb → nextpnr-xilinx → fasm2frames → xc7frames2bit, `regymm/openxc7`) is genuinely working and **hardware-verified** for this board: `fpga/openxc7-synth/Makefile.200t`, `ax7203_al321.cfg`, per-format `corona_decode_*_ax7203.v`, `.github/workflows/ax7203-blinky-bitstream.yml`, and a confirmed blinky (`fpga/experience/2026-06-24-ax7203-blinky-openxc7.trinity.md`: DONE lit, LEDs blink; chipdb generation ~317 MB / ~4 min). `#199` reports 39 hardware cells measured on the AX7203 (2026-07-01). Flash path is **OpenOCD + AL321 (FT2232H) cable**, not openFPGALoader. Nothing here needs re-enabling — this issue only *documents* it as the mesh-track baseline.

- **P201/P203 Mini (`xc7z020`, Zynq-7020) — GENUINELY NEW, never flashed.** No chipdb, no board def, no OpenOCD cfg, no PS/FSBL boot path exists anywhere in the repo (a `grep` for `xc7z020` returns nothing; `zynq` appears only as an abstract resource-estimation target). The Mini currently exists only as a docs-link row in `.claude/skills/fpga-synth/SKILL.md`. **The openxc7 Artix-7 flow does NOT transfer to Zynq unchanged** — Zynq PL support in nextpnr-xilinx/prjxray-db must be confirmed, and PS/FSBL boot is a separate concern.

> ⚠️ Scope: this does **not** overlap decode-HW `#200`–`#206` / EPIC `#199` (those are GoldenFloat conformance reusing the *already-proven* AX7203 flow). This issue's **new** deliverable is xc7z020/Zynq PL enablement; the AX7203 content is documentation of the existing baseline for the mesh track.

## Tasks

**AX7203 (document existing baseline — no new enablement):**
- [ ] In `fpga/TOOLCHAIN_COMPARISON.md`, record the AX7203 mesh-track baseline exactly as it exists today: openxc7 synth (`Makefile.200t`, `xc7a200tfbg484-2` chipdb) + **OpenOCD + AL321** flash (`fpga/openxc7-synth/ax7203_al321.cfg`), IDCODE `0x13636093`. Cross-link the proven blinky experience note. Do **not** introduce an openFPGALoader/FTDI path for this board — the AL321/OpenOCD path is the proven one.

**P201/P203 Mini / xc7z020 (the actual new work):**
- [ ] Identify the Mini's JTAG interface (onboard vs external cable) and get a `--detect`/`scan_chain` reading its real Zynq IDCODE. Record it in a new `xc7z020` section of `fpga/IDCODE.md`.
- [ ] Determine whether nextpnr-xilinx / prjxray-db / the `regymm/openxc7` image ships an `xc7z020` device DB. If **yes**, wire a minimal PL-only blinky through the flow. If **no**, record the concrete fallback (e.g. Vivado for the Mini PL) in `fpga/TOOLCHAIN_COMPARISON.md` and mark the gap `[TODO]` — do **not** assume the Artix-7 flow works for Zynq.
- [ ] Explicitly note that Zynq **PS/FSBL boot is OUT OF SCOPE** for this issue (tracked separately). This issue only covers PL fabric bring-up + IDCODE + first PL bitstream path.

## Acceptance criteria

- A `scan_chain`/detect on the **Mini** returns a valid Zynq IDCODE, logged to `fpga/IDCODE.md` with a new `xc7z020` entry.
- `fpga/TOOLCHAIN_COMPARISON.md` has a per-board table with: (a) AX7203 row stating the *existing proven* path (`xc7a200tfbg484-2` chipdb + OpenOCD/AL321, IDCODE `0x13636093`); (b) a new `xc7z020` row stating the exact PL flow **or** an explicit `[TODO]`/Vivado-fallback if no open device DB exists; (c) QMTECH 100t row unchanged.
- Either a minimal PL-only bitstream is produced for the Mini, **or** the blocking gap (missing xc7z020 device DB) is documented with the chosen fallback — not silently assumed.
- No `/Users/playra/...` paths introduced; all new commands use `/Users/ssdm4/Desktop/PROJECTS/CLAUDE/trinity/fpga/...` or `$SCRIPT_DIR`.
- No claim that the AX7203 openxc7 flow runs on the Zynq unmodified.

## Dependencies

- **blocked_by:** `skill-fix-fpga-synth` — *fix(skill): correct fpga-synth SKILL.md hardcoded playra path + wrong xc7a35t target* (skill must point at the real boards/paths before Mini bring-up is driven through it).
- Feeds the P0 first-flash issue and the drone-mesh EPIC.

---

phi^2 + phi^-2 = 3