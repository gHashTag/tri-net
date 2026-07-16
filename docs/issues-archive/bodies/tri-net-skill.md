## Goal
Create an on-disk `tri-net` Claude skill under `trinity/.claude/skills/tri-net/` that captures the honest Phase-0 status of the TRI-NET drone-mesh track (both boards now physically connected), with `-sim` markers on every unverified claim.

## Context
The FPGA hardware is now **physically connected** (both boards in hand): ALINX **AX7203** (Artix-7 `xc7a200t`) as the bench/ground compute + mesh + video node, and **P201/P203 Mini** (Zynq-7020 `xc7z020` + AD9361 SDR) as the flying radio-PHY node. This unblocks Phase 0.

Honest status per report v2.2 (single source of truth): FPGA **never flashed** on a real Mini node; toolchain **not set up**; the `trios-mesh` daemon (ETX routing, X25519 + ChaCha20-Poly1305) passes unit tests **in simulation only** and **has never run on real hardware** — `trios-mesh` does not yet exist as a repo or on disk. This is a **documentation** task: capture that reality on disk as a skill so the drone-mesh track has a single honest reference, kept **separate** from the `fpga-matrix` / GoldenFloat number-format track (#199–#206). No code or RTL is produced here.

**Naming disambiguation (do not conflate):** existing issues #48 (`TRI-NET-G1` — "Trinity Ternary Internet Node", a USB-3 ternary-compute silicon node) and #61/#79 ("TRI NET" architecture) belong to the **ternary-computing / silicon** track. This skill documents the **TRI-NET drone-mesh internet-delivery** track (relay drones + fixed nodes + radio-PHY). Same "TRI-NET" name, different track — the skill must state this so readers don't merge them.

## Preconditions
- The `drone-mesh` label does **not** yet exist in `gHashTag/trinity-fpga` (only `documentation` exists). Ensure the `drone-mesh` label is created (or the drone-mesh EPIC that introduces it is landed) **before** filing this issue, otherwise `gh issue create --label drone-mesh` will fail. See Acceptance criteria.

## Tasks
- [ ] Create dir `trinity/.claude/skills/tri-net/` and `trinity/.claude/skills/tri-net/references/`.
- [ ] Write `SKILL.md` with YAML frontmatter (`name: tri-net`; `description:` covering mesh/swarm/radio-PHY/drone-C2 work; `argument-hint: <phase or task>`) and body sections:
  - `Honest Phase-0 Status` — FPGA NEVER flashed on a real Mini; toolchain NOT set up; `trios-mesh` sim-only, never on hardware; state the rule that every unverified claim carries a `-sim` marker.
  - `Boards` — AX7203 `xc7a200t` (bench: mesh+video+compute via 2xGbE + HDMI; openxc7 flow partially works here); P201/P203 Mini `xc7z020` + AD9361 (flying SDR radio node; onboard PA only 10–15 dBm, needs **external PA+LNA @5.8GHz** for range). Note explicitly: the AX7203 openxc7 synth flow does **NOT** apply to the Zynq Mini — Mini bring-up is a separate, not-yet-started toolchain track (`-sim`/unstarted).
  - `Phases P0–P5` — one line each (P0 toolchain+first-flash wk1 → P1 OFDM 5.8GHz + 2-hop IP-mesh bench via attenuators/iperf3 wk2-3 → P2 roof/mast nodes 10–30m, one shared uplink over 3-node triangle = DEMO GATE + self-heal wk5-6 → P3 video-radio C2 multiplex wk6-8 → P4 tethered hexacopter AT&T Flying-COW power+fiber 24/7 mo3-5 → P5 free GPS-held swarm mo6+).
  - `References` — link the 4 ref files below.
  - `Repos` — `trinity`, `trinity-fpga` (**issues home**), `openFPGALoader`, `trios-mesh` (**to be created**).
- [ ] Write `references/roadmap-mvp.md` — P0–P5 timeline + BOM reality note (3x AX7203 = bench mesh+video demo vs Mini = flying MVP node).
- [ ] Write `references/tech-tree.md` — mirror the structure of `fpga/TECH_TREE.md` (layered ASCII stack, module dependency graph, status table) with an explicit **`-sim` status column**: App/IP-mesh → `trios-mesh` L2/L3 (ETX, X25519, ChaCha20-Poly1305) → OFDM PHY 5.8GHz → AD9361 SDR → FPGA (Zynq/Artix) → PA/LNA/antenna. Close with the phi identity footer (match `fpga/TECH_TREE.md`: `φ² + 1/φ² = 3 = TRINITY`).
- [ ] Write `references/drone-mesh.md` — the six `trios-mesh` modules (ETX metric, X25519 handshake, ChaCha20-Poly1305 AEAD, neighbor discovery, TUN/TAP Linux daemon, real-hardware smoke test); the **dual-purpose one-radio** design (video + telemetry + MAVLink-compatible C2, with a **low-latency QoS class for C2**); and the repo-location recommendation (new standalone `gHashTag/trios-mesh`).
- [ ] Write `references/p201mini_p203mini_datasheet_facts.md` — Zynq-7020 `xc7z020` (dual Cortex-A9 + 85K LC), AD9361/AD9363 SDR, 1x GbE, onboard GPS, PPS/10MHz ref input, 85x50mm, 5V/1A, onboard PA 10–15 dBm (external PA+LNA needed for 5.8GHz), **STATUS: never flashed / no toolchain**.
- [ ] Ensure no hardcoded foreign paths (`/Users/playra/...`); use repo-relative or `/Users/ssdm4/Desktop/PROJECTS/CLAUDE/trinity/...`.

## Acceptance criteria
- `trinity/.claude/skills/tri-net/SKILL.md` exists with valid YAML frontmatter (`name: tri-net`) and all five body sections present.
- All four files exist under `references/`: `roadmap-mvp.md`, `tech-tree.md`, `drone-mesh.md`, `p201mini_p203mini_datasheet_facts.md`.
- `grep -r "/Users/playra" trinity/.claude/skills/tri-net/` returns nothing.
- Every hardware-behavior claim that has not been observed on a real board carries a `-sim` marker; the Honest Phase-0 Status section explicitly states FPGA never flashed on Mini, toolchain not set up, and `trios-mesh` is sim-only.
- Board roles are correct: AX7203 = `xc7a200t` bench node; Mini = `xc7z020` + AD9361 flying node (no `xc7a35t` anywhere). The skill states the openxc7 Artix flow does NOT cover the Zynq Mini.
- `references/tech-tree.md` mirrors `fpga/TECH_TREE.md` sectioning and includes a `-sim` status column.
- The `drone-mesh` label exists in `gHashTag/trinity-fpga` before this issue is filed (`gh label list --repo gHashTag/trinity-fpga | grep drone-mesh` returns a row); if absent, create it or land the drone-mesh EPIC first.

## Dependencies
- blocked_by: `skill-fix-fpga-synth` (fix `trinity/.claude/skills/fpga-synth/SKILL.md` hardcoded `/Users/playra/trinity-w1/fpga/openxc7-synth/*.bit` path and `xc7a35t` Board Target first, so the two skills present consistent board facts and paths). Verified: that skill currently hardcodes `/Users/playra/...` and targets `xc7a35t`.
- precondition: `drone-mesh` label must exist in `gHashTag/trinity-fpga` (introduced by the drone-mesh EPIC) before this issue can be created with that label.

φ² + φ⁻² = 3