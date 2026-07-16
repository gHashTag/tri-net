**Goal:** Fix two defects in `.claude/skills/fpga-synth/SKILL.md` — a foreign hardcoded bitstream path and a board target that matches no connected hardware.

## Context

Now that the FPGA hardware is physically connected (ALINX AX7203 + P201/P203 Mini), P0 toolchain bring-up is unblocked and the `fpga-synth` skill will actually be invoked against real silicon. Two bugs make it wrong today:

1. **Line 13** lists available bitstreams via `ls -la /Users/playra/trinity-w1/fpga/openxc7-synth/*.bit` — a foreign user (`playra`) and a nonexistent tree (`trinity-w1`). On this machine the user is `ssdm4` and the repo lives at `/Users/ssdm4/Desktop/PROJECTS/CLAUDE/trinity`, where the bitstreams actually exist (`fpga/openxc7-synth/*.bit`: `blink.bit`, `trinity_core.bit`, `vsa_coproc.bit`, etc.). The `ls` returns nothing on this box, so the skill shows an empty bitstream list. Same `playra`/`trinity-w1` defect class flagged in `AUTO_FLASH.sh`, `JTAG_TROUBLESHOOTING.md`, and both `FLASH_HISTORY.md` files — this issue fixes only the skill.

2. **Lines 31-32** declare `Board Target: Artix-7 (xc7a35t) via openXC7`. **No connected board is `xc7a35t`.** That part number came from the stale `constraints/arty_a7.xdc` (Digilent Arty A7). The real connected boards are the ALINX AX7203 (`xc7a200t`) and the P201/P203 Mini (`xc7z020`).

The skill file (`.claude/skills/fpga-synth/SKILL.md`, target repo checkout at `/Users/ssdm4/Desktop/PROJECTS/CLAUDE/trinity`) is otherwise fine — steps 1-5 and the Key Files section stay.

## Tasks

- [ ] `SKILL.md` line 13: change `!\`ls -la /Users/playra/trinity-w1/fpga/openxc7-synth/*.bit 2>/dev/null\`` to the repo-relative `!\`ls -la fpga/openxc7-synth/*.bit 2>/dev/null\`` (the skill runs from repo root; no absolute foreign path).
- [ ] `SKILL.md` lines 31-32: replace the single `Board Target` line with BOTH real connected boards and their roles:
  - `ALINX AX7203 — Artix-7 xc7a200t (1GB DDR3, 2x GbE, HDMI in/out) — bench compute / mesh+video demo node, openXC7 synth flow`
  - `P201/P203 Mini — Zynq-7020 xc7z020 (dual Cortex-A9 + AD9361 SDR) — flying radio node; PL synth TBD (needs xc7z020 chipdb + PS boot, not via openXC7 today)`
- [ ] Verify no other `/Users/playra` or `xc7a35t` or `trinity-w1` string remains in `SKILL.md` (`grep -nE 'playra|xc7a35t|trinity-w1' .claude/skills/fpga-synth/SKILL.md` returns nothing).
- [ ] Sanity-run the skill's live commands from repo root: `ls -la fpga/openxc7-synth/*.bit` lists real `.bit` files.

## Acceptance criteria

- `grep -nE 'playra|xc7a35t|trinity-w1' .claude/skills/fpga-synth/SKILL.md` → no matches.
- From `/Users/ssdm4/Desktop/PROJECTS/CLAUDE/trinity`, the line-13 command lists the actual bitstreams under `fpga/openxc7-synth/` (non-empty).
- The `Board Target` section names exactly `xc7a200t` (AX7203) and `xc7z020` (Mini) — and no longer names `xc7a35t`.

## Dependencies

None (`blocked_by`: none). Independent P0 doc fix; peer to the broader `/Users/playra` path cleanup across `fpga/` scripts and docs, and to the new on-disk `tri-net` skill — none of those block this.

phi^2 + phi^-2 = 3