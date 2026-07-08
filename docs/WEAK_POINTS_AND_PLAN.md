# TRI-NET — Weak Points → Decomposed Plan (2026-07-08, loop iteration 1)

Ranked risk assessment of the proven baseline (3× P201Mini, CSMA BPSK radio
mesh, wire-free internet-over-radio) and the work items that retire each risk.
Ranked by impact × how-often-it-bites-now.

## Ranked weak points

| # | Weak point | Bites | Fix type | Work item |
|---|-----------|-------|----------|-----------|
| 1 | **No auto channel-scan** — 2.4 GHz interferers hop across the band over minutes; the jammed node goes deaf (floor 20→130+). No single band keeps all links up. | Every session | SW (selection); spectrum is physics-gated | **W1** ✅ started |
| 2 | **No FEC** — one bit error fails the AEAD tag → whole ≤255B frame dropped. Marginal links drop frames constantly; only the 8× FETCH retry hides it. | Constant on non-bench links | SW | **W2** |
| 3 | **Security is a stub** — every X25519 key = `SHA256("…/node/"‖id)`, zero secret entropy. Anyone can derive any key, decrypt all, impersonate any node. Real `Handshake` exists in crypto.rs but is unused. | 100% vs any real adversary | SW (key provisioning + on-air handshake) | **W3b** |
| 4 | **Replay-counter desync on restart** — a rebooted node returns at counter 0; peers reject it as replay → can't rejoin without whole-mesh restart. Kills self-heal + battery nodes. | Every reboot/crash/brownout | SW | **W3** |
| 5 | **Single gateway = SPOF** + non-persistent DNS. Kill the uplink node → whole mesh loses internet. | Deterministic on gateway loss | SW (multi-gateway/election) | **W5b** |
| 6 | **Half-duplex single-channel ceiling** — ~1 frame per hundreds of ms goodput. The 7.68 Msym/s headline is the 30.72 MSPS bench capture, NOT the 4 MSPS daemon. Fatal for video. | Always (architectural) | HW (FPGA PL) + TDMA | **W6** |
| 7 | **CSMA sense latency (~4-6ms) > guard (3ms)** + no RTS/CTS → hidden-terminal collisions. Reduces but doesn't prevent collisions. | Rises with load/nodes | Mixed (FPGA offload / TDMA via GPS PPS) | **W7** |
| 8 | **Scaling past 3 nodes** — O(N²) AEAD-opens system-wide; no forwarding dedup (TTL=8 only) → broadcast-storm risk; shared channel divides capacity. | Immediately past 3 | Mixed (dedup=SW easy) | **W8** |
| 9 | **Onboard PA 10-15 dBm** — bench-only range; real range needs external +27-33 dBm PA+LNA (BOM unspecified). | Blocks all field range | HW/procurement | **W-HW1** |
| 10 | **Board-12 TX/RX self-jam** — poor isolation; masked by post-notch cal + TXGAIN=-12 (which cuts range). | Board-specific, persistent | HW (masked in SW) | **W-HW2** |
| 11 | **Power/thermal uncharacterized** — continuous 4 MSPS RX+TX+demod on dual-A9; +PA adds ~1W; not measured. | Latent → hard once battery+PA | HW | **W-HW3** |
| 12 | **Regulatory** — 2.4 GHz OTA now; +PA breaks ≤100 mW ISM EIRP; stale "no OTA Thai" note in modem.rs. | Gates deployment | Legal/process | **W-REG** |
| 13 | **No TUN/real IP** — only a hardcoded FETCH msg type; real packets (ping/curl/iperf3, M3 2-hop) not wired to radio; 255B MTU needs fragmentation. | Caps at "demo" | SW | **W4** |
| 14 | **Wire-free deploy chicken-and-egg** — 824KB binary over console breaks the session; every fix to a wire-free node needs Ethernet replug/SD swap; no over-the-mesh update. Ramdisk wipes /tmp. | Every wire-free code change | SW/ops (gated by #1/#2) | **W-OPS** |

## Decomposed plan (software-first, unblock order)

**Tier 1 — high leverage, do next (each unblocks later work):**
- **W1 auto channel-scan** ✅ *this iteration*: startup scan picks a clean channel (`TRIOS_SCAN=1`, priority list, first non-jammed). Proven on board 11 (scanned 7 ch, picked 2440). **Remaining W1b:** coordinated multi-node hop — leaf nodes acquire the gateway's channel by listen-scan, or gateway broadcasts a "hop to F" control frame, so nodes agree without a shared `TRIOS_FREQ`.
- **W2 FEC** ✅ *loop iter 3*: `trios-mesh/src/fec.rs` — Hamming(7,4) between the mesh frame and the modem (RadioLink.send encodes, RX decodes after rx_recover). Corrects any single-bit error per 7-bit codeword. 6 host tests pass (incl. corrects-any-single-flip + fec↔modem composition); smoke-clean on board 11. **Remaining W2b:** bit interleaver (spread bursts across codewords) + measure FER drop on a marginal 3-node link.
- **W3 replay re-handshake**: on-air epoch-resync / re-handshake so a rebooted node rejoins in N s. Bundle with **W3b real keys**: provision per-node identity out-of-band, run the existing `Handshake` (Noise-XX) on air. Retires weak points #3 and #4 together.
- **W4 TUN/real IP**: `/dev/net/tun` + kernel NAT on the gateway; real ping/curl over 1 then 2 hops (the deferred M3 iperf3); 255B MTU fragmentation.

**Tier 2 — scaling/robustness:**
- **W8 forwarding dedup** (easy SW): seen-cache keyed by (src,seq) so relays don't re-forward duplicates → kills broadcast-storm risk past 3 nodes.
- **W5b multi-gateway** election + persistent DNS (bake resolv.conf to SD).
- **W7 TDMA** using the board's GPS PPS/10 MHz to schedule slots → removes hidden-terminal collisions + the sense-latency problem.

**Tier 3 — hardware/physics/legal (gate the field vision, not the bench):**
- **W6 FPGA PL modem** (blocked on Vivado — needs Linux/VM/CI): move BPSK→QPSK→OFDM into PL for real throughput.
- **W-HW1 external PA+LNA** (the hard procurement blocker) + link budget.
- **W-HW2/3** TX/RX isolation + power/thermal characterization.
- **W-REG** band + power certification; keep to attenuator/bench until licensed-by-rule.

## Honest one-liner
The demo is real and reproducible; the product claims (secure, self-healing,
multi-node, real-IP, real-range) are each 1-to-several milestones away — the
security claim in particular is currently unbacked by any secret (#3).
