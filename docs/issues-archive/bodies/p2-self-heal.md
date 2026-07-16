## 🎯 Goal
Kill one radio link (or power off one relay node) in the 3-node triangle and prove the ETX metric re-routes traffic around the failure so internet service continues on the surviving nodes — with a recorded, measurable convergence-time pass/fail threshold. **This is the go/no-go DEMO GATE.**

## Context
Part of the **TRI-NET drone-mesh** track (EPIC — separate from the `fpga-matrix`/GoldenFloat epic #199). This is the last `trios-mesh` milestone (**M5**) and the top of the whole MVP: it turns a working shared-uplink mesh into a *self-healing* one.

Honest status **[sim-only]**: `trios-mesh` (ETX routing + X25519 handshake + ChaCha20-Poly1305 AEAD) passes unit tests **in simulation ONLY**; it has never run on real hardware and the repo does not yet exist on disk (`gh repo view gHashTag/trios-mesh` → "Could not resolve"). No self-healing re-route has ever been observed on silicon. The **convergence-time threshold is currently UNDEFINED** — no source doc specifies it; defining it is part of this issue.

Why now: both FPGA boards are physically connected. Metrics/video capture for this gate run on the **AX7203** (Artix-7 `xc7a200t`, bench compute/video node); the mesh daemon runs on the **Mini** (Zynq-7020 `xc7z020` + AD9361) — on the ARM Cortex-A9 PS cores that drive the 5.8GHz radio (this is PS software, NOT the openxc7/Artix-7 FPGA synth flow, which does not apply to the Zynq). The demo record (video + throughput/latency/encryption metrics) is the deliverable the partner proposal promised (Apache-2.0 code + Zenodo DOI).

**RF honesty note:** the Mini's onboard PA is only ~10-15 dBm — insufficient for real 10-30m rooftop/mast 5.8GHz links. Any over-the-air triangle (P2 setup) requires the **external PA+LNA @5.8GHz** per report v2.2. Bench validation of this milestone is done over **cabled attenuators** (no free-space range is claimed here); the external PA+LNA must be in place before the rooftop variant of Test A/B.

Blocked by **p2-shared-uplink** (M4): one uplink NAT/routed across the 3-node triangle must already work before we can prove service *survives* a failure.

## Tasks
- [ ] **Define the pass/fail threshold** first: pick a convergence-time budget `N` (proposal: re-route completes and TCP flow resumes in **< 5 s** on link loss; < 10 s on full node power-off). Record `N` + rationale in `trios-mesh` README and reference here — it was previously undefined.
- [ ] Instrument `trios-mesh` ETX layer: log HELLO-probe loss, per-neighbor ETX table transitions, and next-hop change events with timestamps (needed to *measure* convergence, not just observe it).
- [ ] Set ETX HELLO interval + neighbor-expiry timeout so worst-case detection ≤ `N` (document the chosen values; they bound convergence).
- [ ] Deploy the 3-node triangle (per **p2-shared-uplink** setup): one node holds the uplink (4G/Starlink Mini), all 3 route internet over the 5.8GHz mesh. For any over-the-air link, confirm the external PA+LNA is fitted (onboard PA 10-15 dBm is insufficient for range).
- [ ] **Test A — link kill:** attenuate/disconnect one radio link mid-`iperf3`; confirm ETX drops the dead neighbor, re-routes via the alternate hop, and the flow resumes. Record convergence time.
- [ ] **Test B — node power-off:** cut power to one relay node; confirm surviving nodes keep internet service and re-route. Record convergence time.
- [ ] **Test C — recovery:** restore the link/node; confirm the mesh re-adopts the shorter path (ETX re-converges) without flapping.
- [ ] Capture on **AX7203**: demo video + throughput (`iperf3` before/during/after failover), latency (`ping` RTT trace across the failover), and encryption confirmation (ChaCha20-Poly1305 AEAD active, X25519 session established).
- [ ] Publish: Apache-2.0 `trios-mesh` code on GitHub + mint a **Zenodo DOI** for the demo artifact (per partner proposal).
- [ ] Log the run to `fpga/FLASH_HISTORY.md` (bitstream SHA + node IDCODEs) and cross-link this issue.

## Acceptance criteria
- Convergence-time threshold `N` is **documented** (was undefined) with the chosen HELLO/timeout values that enforce it.
- **Test A** (link kill): ETX re-routes and `iperf3` throughput recovers to ≥ 80% of pre-failure baseline within `N` seconds; measured convergence time recorded.
- **Test B** (node power-off): the two surviving nodes keep internet reachability (uplink-side `ping 8.8.8.8` succeeds through the mesh) within `N` seconds; recorded.
- **Test C**: after recovery, ETX re-selects the direct/shorter path with no persistent route flapping.
- Encryption proven live during failover: X25519 handshake logged + ChaCha20-Poly1305 AEAD on every datagram (no plaintext fallback).
- Deliverable published: demo video + metrics table (throughput/latency/encryption) + Apache-2.0 repo + Zenodo DOI.
- All results run on real hardware (Mini radio nodes + AX7203 capture) — the `[sim-only]` marker is removed for M5 only after these pass. Over-the-air runs use the external PA+LNA; bench runs use cabled attenuators (record which).

## Dependencies
- **blocked_by:** `p2-shared-uplink` — *feat(mesh): trios-mesh M4 shared single-uplink NAT/route across 3-node triangle*. (M5 self-healing cannot be tested until M4's shared-uplink service exists.)
- Upstream chain (context): M1 first-run-on-ARM → M2 IP-over-radio (ETX tun/netdev) → M3 iperf3 over 2 hops → **M4 shared uplink** → **M5 self-heal (this)**.
- `trios-mesh` repo must exist (to be created from scratch, recommended standalone `gHashTag/trios-mesh`).
- Hardware: external PA+LNA @5.8GHz required for over-the-air links (Mini onboard PA 10-15 dBm insufficient).

---

phi^2 + phi^-2 = 3