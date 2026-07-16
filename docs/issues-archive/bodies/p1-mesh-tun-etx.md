## Goal
Run ordinary IP apps (ping, iperf3, later MAVLink C2) over the 5.8 GHz mesh: open a Linux TUN on each Mini, route packets by a **real ETX** metric, encrypt over the radio socket, decrypt back into TUN.

## Context
**Honest status:** trios-mesh does not exist as a repo or on disk. Its crypto/routing pass unit tests in **simulation only** — never on hardware `[-sim]`. This issue is **trios-mesh MILESTONE 2** and is greenfield.

Board: **P201/P203 Mini** (Zynq-7020 `xc7z020`, dual Cortex-A9, AD9361 SDR) — the flying node. The daemon runs on the Mini's PS-side ARM-Linux (aarch32 Cortex-A9), *not* on the AX7203 (no hard CPU, too heavy to fly). Cross-compile target: `arm-linux` — this exercises real sockets + TUN ioctls the sim never touched.

Now that the FPGA is physically connected and P0 gates the first flash, M2 sits directly on top of the PHY: `p1-ad9361-phy` must expose a radio socket / sample interface for the daemon to send/recv frames. Prior milestone `p1-mesh-repo` (M1: repo + X25519 handshake + ChaCha20-Poly1305 session on real ARM-Linux) provides the crypto session this milestone encrypts with.

## Tasks
- [ ] `daemon/`: open a Linux TUN device via `/dev/net/tun` `TUNSETIFF` ioctl; assign mesh IP from `10.42.0.0/24` (one per node); bring `if` up.
- [ ] Read IP packets off TUN; parse dst; look up next-hop in the routing table.
- [ ] `routing/`: implement a **real ETX metric** — periodic HELLO probes, per-neighbor delivery-ratio (df·dr) measurement, ETX table, best-next-hop selection. **Replace any hop-count stub.**
- [ ] Wire send path: on TX, AEAD-encrypt the IP frame with the ChaCha20-Poly1305 session from M1 (`crypto/`, 96-bit nonce = counter+direction, never reused; replay window), then write to the `p1-ad9361-phy` radio socket. MTU-aware framing (account for AEAD tag + mesh header).
- [ ] Wire recv path: read frame from radio socket → decrypt/verify tag → inject back into TUN.
- [ ] `smoke/`: 2-node real-hardware smoke — bring up TUN on both Minis, `ping` across the encrypted link, then `iperf3` over 1 hop. **Not a unit test.**
- [ ] 3-node relay: `iperf3` across a middle node = **2 hops** (this is M3's gate, but wire the relay path here).
- [ ] Cross-compile the daemon to `arm-linux` Cortex-A9; document the build in the repo README.
- [ ] Log the run (TUN ifname, mesh IPs, ETX table snapshot, throughput) into `fpga/FLASH_HISTORY.md`-style record in the trios-mesh repo.

## Acceptance criteria
- [ ] `ip addr` on each Mini shows a `tun0`-class device with a `10.42.0.x/24` mesh IP, link UP.
- [ ] `ping 10.42.0.<peer>` succeeds across the radio link; `tcpdump` on the radio socket shows **only** ChaCha20-Poly1305 ciphertext (no plaintext IP).
- [ ] `iperf3` reports a non-zero throughput baseline over 1 hop, and > 0 Mbit over **2 hops** through a relay node.
- [ ] ETX table is populated from live HELLO probes (delivery ratio, not hop-count); killing a link changes the selected next-hop (full self-heal is M5, but next-hop must react here).
- [ ] Any AEAD tag mismatch / replayed nonce is dropped and logged (no plaintext injected into TUN).

## Dependencies
- **blocked_by:** `p1-mesh-repo` — trios-mesh MILESTONE 1: repo + X25519 handshake + ChaCha20-Poly1305 session on real ARM-Linux.
- **blocked_by:** `p1-ad9361-phy` — AD9361 5.8 GHz OFDM PHY exposing the radio socket / sample interface this daemon sends/recvs over.

---
phi^2 + phi^-2 = 3