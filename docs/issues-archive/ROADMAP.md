# TRI-NET Drone-Mesh — Execution Roadmap (Phase 0 → Phase 2 DEMO GATE)

> **Trigger:** FPGA hardware now physically connected (BOTH boards). Phase 0 (real toolchain bring-up + first flash) is unblocked. Everything prior was simulation-only.
> **Anchor:** φ² + φ⁻² = 3.

## Honest status (single source of truth — report v2.2)
- FPGA has **NEVER** been flashed on a real Mini (Zynq-7020) node. No Zynq toolchain, board def, chipdb, or IDCODE entry exists.
- On AX7203 (xc7a200t) the **openxc7 synth flow only *partially* works**; the only ever-flashed hardware event was one small LED design on a now-absent QMTech xc7a100t, verified weakly by a phone-camera LED (project docs call this insufficient). Treat AX7203 first-flash as **new, unproven** work.
- **trios-mesh does NOT exist** — no repo, no code on disk. Passes unit tests **in simulation only**. Must be built from scratch.
- Radio-PHY / 5.8 GHz OFDM / AD9361 bring-up / external PA+LNA = **all greenfield**, zero on-disk code.
- Every unverified capability carries a **`-sim`** marker until proven on hardware.

## Two-board division of labor
| Board | Chip | Role |
|---|---|---|
| **ALINX AX7203** | Artix-7 `xc7a200t` (FBG484, IDCODE ~`0x13636093` — verify) | Bench / ground node: compute + routing + video-radio (HDMI-in) + 2×GbE mesh. 3× = the Smeta_MVP bench demo. Onboard FTDI USB-JTAG. |
| **P201/P203 Mini** (== AntSDR E200 class) | Zynq-7020 `xc7z020` (dual Cortex-A9 + PL) + AD9361 SDR | **Flying MVP node**: 5.8 GHz radio-PHY, GPS/PPS/10 MHz, runs trios-mesh on ARM cores. 85×50 mm, 5V/1A. Onboard PA only 10–15 dBm → **needs external PA+LNA @5.8 GHz for range**. |

**Critical distinction — cannot be vibe-coded:** RF link budget, AD9361 5.8 GHz reach (AD9361 required; AD9363 caps at 3.8 GHz), OFDM PHY, and self-healing convergence are **hardware/physics-gated**. They pass or fail on the bench, not in review.

---

## Phase 0 — Toolchain bring-up + FIRST REAL FLASH (wk 1)
Get a real bitstream running on **both** boards and a booted Linux on the Mini.

**Work**
- Host: stand up openFPGALoader (gHashTag fork) + openxc7 (Yosys → nextpnr-xilinx → fasm2frames) for both real parts. Fix `fpga-synth` SKILL.md (foreign `/Users/playra` path → repo-relative; `xc7a35t` → real boards).
- AX7203: author a **real** `xc7a200t` XDC (clock, LEDs, polarity — do NOT reuse arty_a7.xdc or QMTech U22/T23), obtain/build an `xc7a200t` chipdb, JTAG-detect via onboard FTDI (rule out the `HARDWARE_TEST_RESULTS.md` CPLD-`0xFFFE`/TDO-stuck fault), flash a blinky = **first-flash gate**.
- Mini: boot ARM-Linux from SD, USB-C serial console, confirm AD9361 enumerates + onboard GPS + PPS/10 MHz lock. Scope PL bitstream + PS boot separately (no Zynq flow exists today → Vivado fallback allowed).
- Generalize `AUTO_FLASH.sh` (`/Users/playra` → `SCRIPT_DIR`, per flash.sh/xvc_flash.sh template) and parameterize cable type.
- Procure: 3× 12V/3A PSU (absent from all board kits).

**Exit criteria (verifiable)**
1. `openFPGALoader --detect` reads correct IDCODE on AX7203 (~`0x13636093`) AND Mini (`xc7z020`), logged to `FLASH_HISTORY.md`.
2. AX7203 runs a blinky, verified by **video + frame-brightness analysis** (not a single photo, per `COMMON_PITFALLS.md`), ideally + UART loopback.
3. Mini boots to a Linux shell over USB-C; AD9361 + GPS + PPS lock confirmed in `dmesg`/iio.

**Critical path:** AX7203 chipdb+XDC → first flash. Mini Zynq boot model is the long-pole unknown (no prior detect on record).

---

## Phase 1 — Radio-PHY 5.8 GHz + 2-hop encrypted IP-mesh on bench (wk 2–3)
Two real Minis exchanging encrypted IP over 5.8 GHz through attenuators, then a 3rd for 2 hops.

**Work**
- Mini: bring up AD9361 TX/RX @5.8 GHz; implement 5.8 GHz OFDM PHY (**single-carrier fallback ready** — OFDM is the highest-risk item). Link two Minis over SMA attenuators (bench-safe, not over-air).
- **trios-mesh (new repo `gHashTag/trios-mesh`)**: M1 first run on real ARM-Linux (X25519 handshake + ChaCha20-Poly1305 AEAD on-device, previously `-sim`); M2 IP-over-radio as a Linux TUN/netdev with ETX metric; M3 iperf3 over 2 hops through a middle Mini.
- AX7203 parallel: 2×GbE data path + HDMI-in capture path (bench video-radio groundwork).
- Procure: **external PA+LNA @5.8 GHz** (the hard range blocker — no part chosen yet), SMA attenuators (~30–60 dB), RG316 SMA cables, range antennas.

**Exit criteria (verifiable)**
1. `ping` succeeds across an encrypted 1-hop 5.8 GHz link between two Minis (attenuated cable); packet capture shows ChaCha20-Poly1305 framing, not plaintext.
2. `iperf3` throughput baseline recorded 1-hop, then **over 2 hops** through the relay Mini; loss/latency logged.
3. ETX table on each node shows measured per-neighbor metric (not hop-count stub).

**Critical path:** AD9361 5.8 GHz TX/RX → PHY → trios-mesh TUN. If OFDM slips, single-carrier holds the window.

---

## Phase 2 — DEMO GATE: 3-node triangle, ONE shared uplink, self-healing (wk 5–6)
"Starlink without satellites" service MVP: one uplink shared over the mesh; kill a node, service survives.

**Work**
- Deploy 3 nodes on roofs/masts 10–30 m as a triangle (Mini radio; add AX7203 compute per node only where mount/weight allows).
- Attach **ONE** uplink modem (4G router or Starlink Mini) to a single node.
- trios-mesh M4: NAT/route that uplink's internet across all 3 nodes over the mesh (a node with no direct uplink reaches internet via 2 hops).
- trios-mesh M5 **SELF-HEALING**: kill one link/node → ETX re-routes → internet continues on survivors; **measure convergence time** (define pass threshold, e.g. re-route < N s — currently undefined, must be set).
- AX7203: capture demo video + throughput/latency/encryption metrics.
- Procure: uplink modem + data plan/SIM, mast/roof mounts, weatherproofing, PoE/long power runs.

**Exit criteria (verifiable) = GO/NO-GO**
1. A laptop on the **non-uplink** node reaches the public internet (e.g. `curl ifconfig.me` returns the uplink's IP) routed over 2 mesh hops.
2. Powering off one relay node → traffic on surviving nodes recovers within the agreed convergence threshold; convergence time logged.
3. Deliverable published: demo video + metrics + Apache-2.0 code on GitHub + Zenodo DOI (per partner proposal).

**Critical path:** self-healing convergence on real hardware (sim-only today) — this is the DEMO GATE metric.

---

## Beyond the gate (context only)
- **P3** (wk 6–8): video-radio + drone C2 (MAVLink-compatible) multiplexed on the one 5.8 GHz radio; C2 gets a low-latency QoS class.
- **P4** (mo 3–5): tethered hexacopter (AT&T Flying-COW model), power+fiber over tether, 24/7.
- **P5** (mo 6+): free GPS-held swarm, battery rotation.

## Open decisions blocking later phases
- AX7203B GbE port count (1 vs 2) — per-node needs radio-port + user-port; confirm against ALINX manual.
- Flying-node compute placement (Mini-only vs Mini+AX7203) — AX7203 too heavy to fly; C2+routing must fit dual Cortex-A9.
- External PA+LNA part number / gain / link-budget target — unspecified.
- Uplink: 4G vs Starlink Mini + data plan.
- Self-healing convergence pass/fail threshold — undefined.
