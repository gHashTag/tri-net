# tri-net

**TRI-NET drone-mesh** — "Starlink without satellites": a self-organizing mesh/swarm of
relay drones + fixed nodes that share one internet uplink. Part of the Trinity Project.
Anchor: **phi^2 + phi^-2 = 3**.

> Naming: this is the **drone-mesh internet-delivery** track, distinct from the ternary-computing
> "TRI-NET" silicon-node work.

## Honest Phase-0 status (report v2.2)
Every unverified hardware claim carries a `-sim` marker.
- FPGA **never flashed** on a real Mini (Zynq-7020) node; no Zynq toolchain. `-sim`
- `trios-mesh` (ETX + X25519 + ChaCha20-Poly1305) passes unit tests **in simulation only**; no code yet. `-sim`
- Radio-PHY / 5.8 GHz OFDM / AD9361 / external PA+LNA = greenfield. `-sim`
- **AX7203 is real and proven**: openXC7 flow flashes it on silicon (OpenOCD + AL321, IDCODE `0x13636093`).

## Boards
| Board | Chip | Role |
|---|---|---|
| ALINX AX7203 | Artix-7 `xc7a200t` (IDCODE `0x13636093`) | bench compute + video-radio + 2xGbE mesh (proven) |
| P201/P203 Mini | Zynq-7020 `xc7z020` + AD9361 SDR + GPS/PPS | flying MVP radio node (never flashed; external PA+LNA @5.8 GHz needed) |

## Roadmap
- **P0** (wk1) — toolchain bring-up + first flash (Mini boot ARM-Linux + AD9361/GPS/PPS; AX7203 sanity).
- **P1** (wk2-3) — AD9361 5.8 GHz + OFDM PHY; `trios-mesh` M1 crypto-on-ARM -> M2 TUN/ETX -> M3 iperf3 over 2 hops (bench attenuators).
- **P2 = DEMO GATE** (wk5-6) — 3-node triangle, ONE shared uplink over the mesh, M4 + M5 self-healing (measured convergence). Deliverable: video + metrics + Apache-2.0 + Zenodo DOI.
- **P3** video-radio = drone C2 (MAVLink) on one radio · **P4** tethered drone (Flying-COW) · **P5** free swarm.

See the [`drone-mesh`](https://github.com/gHashTag/tri-net/issues?q=is%3Aissue+label%3Adrone-mesh) issues (EPIC + P0/P1/P2 children).

## Related repos
`gHashTag/trinity` · `gHashTag/trinity-fpga` (FPGA infra) · `gHashTag/openFPGALoader` · `gHashTag/trios-mesh` (to be created).
