## 🎯 Goal
trios-mesh **MILESTONE 3** + **P1 exit gate**: encrypted ping across a 1-hop 5.8GHz link, iperf3 1-hop baseline, then iperf3 **over 2 hops** through a relay Mini via SMA attenuators — with per-neighbor ETX and packet-capture proof the link is ChaCha20-Poly1305, not plaintext.

## Context
Honest status (report v2.2, SSOT): trios-mesh passes unit tests **in simulation only** — never on real hardware. This issue is the first time routing + crypto run end-to-end over a real 5.8GHz radio link across a relay node. It graduates the trios-mesh milestone ladder (M1 crypto-on-device → M2 tun/ETX → **M3 2-hop iperf3** → M4 shared uplink → M5 self-heal) and closes P1.

Radio track is on the **Mini** (P201/P203, Zynq-7020 XC7Z020 + AD9361, dual Cortex-A9 ARM-Linux) — it owns the AD9361 5.8GHz PHY and runs the daemon on its ARM cores. Needs **3 Minis** (2 endpoints + 1 relay). Onboard PA is only 10–15 dBm, so the bench link is over **SMA attenuators (~30–60 dB) + RG316 cables**, NOT over-air — repeatable and safe (external PA+LNA is a later range item, not required here). Parallel AX7203 (XC7A200T) track brings up the 2×GbE data path + HDMI-in capture for the later bench video-radio node; it does not block the gate.

## Tasks
- [ ] **[dep]** land `p1-mesh-tun-etx` first: TUN device up on each Mini, mesh subnet `10.42.0.0/24`, ETX routing table, X25519 + ChaCha20-Poly1305 session.
- [ ] **[Mini A↔B]** bring up single 1-hop 5.8GHz link over SMA attenuators; complete X25519 handshake; `ping 10.42.0.2` succeeds across the encrypted link.
- [ ] **[capture]** `tcpdump`/logic-capture the radio-facing socket during the ping; confirm AEAD framing (ChaCha20-Poly1305, 96-bit nonce = counter+direction, replay window) — payload MUST NOT be plaintext ICMP.
- [ ] **[Mini A↔B]** `iperf3 -s` on B, `iperf3 -c 10.42.0.2` on A → record **1-hop throughput baseline** (Mbit/s), loss, RTT.
- [ ] **[Mini A→R→B]** insert 3rd Mini as relay R; attenuate the direct A↔B path so traffic is forced through R (2 hops); re-run `iperf3` A→B **over 2 hops** through the attenuator chain.
- [ ] **[log]** record per-hop loss, latency, and per-neighbor **ETX** from the routing table for A→R→B; confirm ETX picked the 2-hop path when the direct link was degraded.
- [ ] **[AX7203, parallel]** bring up 2×GbE data path; start HDMI-in capture path (bench video-radio prep). Non-blocking for this gate.
- [ ] **[FLASH_HISTORY.md]** log the Mini IDCODEs + first radio-link session (this is new hardware territory — `fpga/FLASH_HISTORY.md` currently records only an XC7A100T flash, no Mini/Zynq entry).

## Acceptance criteria
- `ping` across the 1-hop link succeeds; packet capture shows **ChaCha20-Poly1305 ciphertext + Poly1305 tag**, zero plaintext ICMP bytes.
- 1-hop `iperf3` reports a stable throughput baseline (record the number; no hard threshold — this establishes the baseline).
- 2-hop `iperf3` A→R→B completes with logged loss/latency; **2-hop throughput ≥ ~50% of 1-hop baseline** and loss within a documented bound.
- Routing table shows a sane per-neighbor **ETX** and confirms the 2-hop path was selected when the direct A↔B link was attenuated out.
- All measurements reproducible on the SMA-attenuator bench (not over-air); Mini IDCODEs + session logged in `fpga/FLASH_HISTORY.md`.
- **[not in this gate]** self-healing re-route (M5) and shared uplink NAT (M4) are explicitly out of scope; AX7203 GbE/HDMI is prep only.

## Dependencies
- **blocked_by:** `p1-mesh-tun-etx` (trios-mesh M2 — TUN netdev + IP routing over the OFDM PHY with ETX metric). Also implicitly needs M1 (crypto on real ARM-Linux) and the P1 AD9361 5.8GHz PHY bring-up.
- Purchases gating this gate: 3× P201/P203 Mini (Zynq-7020 + AD9361) radio nodes, SMA attenuators + RG316 SMA-SMA cables, 3× 5V PSU for the Minis. (External PA+LNA is a range item, not required for the attenuator bench.)

---
phi^2 + phi^-2 = 3