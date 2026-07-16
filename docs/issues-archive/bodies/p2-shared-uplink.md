## Goal
Route ONE physical uplink's internet (4G or Starlink Mini) across a 3-node mesh triangle so a node with **no** direct uplink reaches the public internet over 2 mesh hops — the "Starlink without satellites" service MVP.

## Context
This is the **P2 DEMO GATE** for the TRI-NET drone-mesh track. Honest status: `trios-mesh` passes unit tests **in simulation ONLY** — never on real hardware `[-sim]`; the daemon does not yet exist as a repo (to be created as `gHashTag/trios-mesh`, cross-compiled to arm-linux Cortex-A9 for the Mini's PS). `[-sim]`

Now unblocked because the FPGA hardware is **physically connected** (both boards in hand). Boards for this phase:
- **P201/P203 Mini** = Zynq-7020 `xc7z020` + AD9361 SDR (dual Cortex-A9 ARM-Linux) — runs the `trios-mesh` daemon + 5.8 GHz radio-PHY; the flying/relay node. NOTE: onboard PA is only ~10–15 dBm — an **external PA+LNA @ 5.8 GHz (from P1)** is required for any real over-air range; do not assume range from the onboard PA alone.
- **ALINX AX7203** = `xc7a200t` (IDCODE `0x13636093`, part-number field `0x3636`, per `fpga/openxc7-synth/ax7203_al321.cfg`) — already hardware-proven bench compute node for metrics/video capture. The Artix-7 openxc7 flow does **not** apply to the Zynq Mini.

Each of the 3 nodes is deployed **fixed** on a roof/mast at 10–30 m. ONE uplink modem attaches to a single node; `trios-mesh` **MILESTONE 4** = NAT + ETX-routed forwarding of that uplink across the triangle. Multi-hop reach: the far (non-uplink) node reaches the internet via 2 hops. Depends entirely on M3 (iperf3 over 2 hops on attenuators) already passing on real hardware, plus uplink-modem + mast/weatherproofing procurement.

## Tasks
- [ ] **Procure** uplink modem (4G router **or** Starlink Mini) + SIM/data plan — NOT in any current BOM; decide 4G vs Starlink for the deploy site.
- [ ] **Procure** mast/roof mounts, weatherproof enclosures, PoE or extended 12V runs for the 3 elevated nodes (10–30 m).
- [ ] **Procure/verify** external PA+LNA @ 5.8 GHz per Mini node (carried over from P1) — the onboard PA (~10–15 dBm) is insufficient for the elevated-node link budget.
- [ ] **Deploy** 3-node triangle: mount 3× Mini radio nodes (+ AX7203 compute per node where weight/power allows) on masts/roofs 10–30 m; verify each Mini's 5.8 GHz link comes up over-air (external PA+LNA) between all 3 pairs.
- [ ] `trios-mesh` **M4a — NAT**: on the uplink node, add masquerade/NAT from the mesh TUN (`10.42.0.0/24`) to the uplink WAN iface; advertise a default route into the mesh.
- [ ] `trios-mesh` **M4b — default-route propagation**: originate a gateway advertisement so non-uplink nodes install a default route via best-ETX next hop toward the uplink node.
- [ ] `trios-mesh` **M4c — 2-hop forwarding**: confirm the far node's default route resolves through the middle relay (2 ETX hops), IP-forwarding + encrypt/decrypt per hop (X25519 session + ChaCha20-Poly1305 AEAD) `[-sim → hw]`.
- [ ] **Verify** from a laptop on the **non-uplink** node: `curl -s https://api.ipify.org` returns the **uplink modem's public IP** (proves traffic egressed via the shared uplink over 2 mesh hops).
- [ ] **Measure** per-node throughput + latency (iperf3, ping) from each node to the internet; record 1-hop vs 2-hop deltas.
- [ ] **Capture** demo video + metrics on the AX7203 bench node for the partner record.
- [ ] **Log** the run (topology, IPs, ETX tables, throughput) to `fpga/FLASH_HISTORY.md` / a new `MESH_HISTORY.md`; publish Apache-2.0 code to `gHashTag/trios-mesh`.

## Acceptance criteria
- All 3 Mini nodes hold a 5.8 GHz mesh link (external PA+LNA in place); `trios-mesh` neighbor tables show 3 bidirectional neighbors with live ETX metrics.
- Laptop on the **non-uplink** node: `curl https://api.ipify.org` returns the **uplink's public IP** (not the LAN/carrier-NAT of the laptop's own node) — routed over **2 mesh hops**.
- `traceroute`/`ip route get 8.8.8.8` from the far node shows the path traversing the middle relay then the uplink node.
- iperf3 from the non-uplink node to an internet endpoint shows **> 5 Mbit/s** sustained over 2 hops (baseline; single-carrier fallback acceptable).
- Every packet on the mesh path is AEAD-encrypted (ChaCha20-Poly1305, unique 96-bit nonce, replay window active) — verified by a plaintext-scan of a captured radio trace showing no cleartext IP payloads.

## Dependencies
- **blocked_by:** `p1-iperf-2hop` — "feat(mesh): trios-mesh M3 — iperf3 over 2 hops on attenuators". M4 forwarding builds directly on the M3 2-hop path.
- **blocked_by (procurement):** uplink modem + data plan; mast mounts + weatherproofing + elevated power runs; external PA+LNA per node.

---
phi^2 + phi^-2 = 3