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
- **M modem frame-robustness — decision-directed phase tracker** ✅ *this iteration* (commit 61cff89): instrumented failures FIRST (`modem_failure_census`) → 0% sync misses, 100% carrier-corrupt, ~90% byte errors TAIL-biased = carrier phase drift (13-sym pilot residual ω ramps worst at the tail; explains iter8 length-dependence). Fix: 1st-order DD phase loop in the shared `recover_symbols` front-end (both hard+soft benefit), no wire change, no overhead. **Raw FER: 90B σ=0.20 27.8%→0.3%; 200B σ=0.16 23.0%→0.0% — length penalty GONE, residual now AWGN-uniform.** Large link-budget/range extension on the same PHY; unblocks long frames (photo/video). **Downstream: FEC now NET-POSITIVE (~100× fewer lost frames, σ=0.30 39.5%→0.4%) — iter8 verdict honestly reversed (FEC was gated on modem robustness).** HW-smoked board 11 (88 frames self-recovered off real AD9361 IQ, 0 panics). `MODEM_PHASE_TRACKER_RESULTS.md`. Matches competitor read (modem robustness = #1 SW lever before PL). **Next M-step:** QPSK (2×throughput) now that carrier tracking is solid; then PL offload (W6).
- **W1 auto channel-scan** ✅ *this iteration*: startup scan picks a clean channel (`TRIOS_SCAN=1`, priority list, first non-jammed). Proven on board 11 (scanned 7 ch, picked 2440). **Remaining W1b:** coordinated multi-node hop — leaf nodes acquire the gateway's channel by listen-scan, or gateway broadcasts a "hop to F" control frame, so nodes agree without a shared `TRIOS_FREQ`.
- **W2 FEC** ✅ Hamming(7,4) + **W2b bit-interleaver** (block 16cw=112b=14B; burst≤16 corrected, swept test). **W2 measurement (examples/fec_fer_bench) = HONEST NEGATIVE:** Hamming is NET-NEGATIVE at operating SNRs (σ=0.14 raw FER 3.2% vs FEC 6.5%) — 7/4 length + mis-correction outweigh the fix; only helps at the harsh tail. So **FEC is now OPT-IN (TRIOS_FEC=1), default OFF** — mesh never regresses. **A′ done: replaced Hamming with K=5 Viterbi conv code** (src/conv.rs, stronger — recovers 3% BER + triple-error-in-window). **But even Viterbi is NET-NEGATIVE end-to-end** — modem frame-failures (sync/carrier) dominate + rate-1/2 doubles frame length. Commits a364818/c8c003d/70847f6.
- **A″ SOFT-decision demod → soft Viterbi** ✅ *this iteration* (commit c92e878): `modem::rx_recover_soft` keeps the BPSK matched-filter confidence (i8 LLR proxy) → `conv::decode_soft` (correlation branch metric) → `fec::decode_soft`. **Soft is strictly ≥ hard at every SNR** (σ=0.18: 24.8%→24.6% FER) — implemented correctly. **BUT soft FEC is STILL net-negative vs raw** (σ=0.14: raw 2.7% vs soft 5.9%). **Root cause PROVEN by a frame-length sweep:** raw FER rises slowly with length, FEC FER rises ~2× faster (tracks the rate-1/2 length doubling) → frame loss is WHOLE-FRAME-sync-dominated, not bit-dominated; no bit-level decoder can pay for the length it adds. **The lever is modem frame-robustness / higher-rate code / PL offload — NOT a smarter decoder.** FEC stays opt-in default OFF; soft path kept ready. `SOFT_DECISION_FER_RESULTS.md`. Matches the competitor read (soft's ~1.3 dB gain only converts to frame gain once the PHY's dominant failure is bit errors — ours isn't).
- **W3b real keys** ✅: StaticKey::generate/from_bytes/to_bytes; TRIOS_KEY secret file + `peer <id> <addr> <pubkey-hex>` config → real static-static session; falls back to demo key if unprovisioned. Proven on board 11 (public 5ee5c9…). **Closes threat #3.** Commit 78c394a.
- **W3 replay-resync / authenticated FS handshake** ✅ *this iteration*: **B′ core** (commit 8679ae0) = `session_authenticated` mixing static-static (auth) + eph-eph (forward secrecy) + reusable `Ephemeral`; **B′-wire** (commit a20e195) puts it on the air. Plaintext 37 B beacon `[0xE2][sender][eph_pub]` every 3 s, intercepted before the session-open path (so a post-reboot session mismatch can't deadlock the re-key); a peer's NEW ephemeral → `add_link` replaces the session in place. Bootstrap static-static → upgrade to authenticated+FS; **reboot mints a fresh ephemeral so no nonce is ever reused** (closes threat #4). 4 new bin tests incl. two-node seal/open interop; **136 green**. Hardware: beacon TX + self-RX + parse proven on board 11 (`SECURE_HANDSHAKE_RESULTS.md`). **Remaining:** two *physical* boards converging over the air (session upgrade fires only for `sender != me`) — needs board 12/13 replugged; software E2E covers the path meanwhile.
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
The demo is real and reproducible; **security is now genuinely backed** — real
per-node secrets + an on-air authenticated forward-secret handshake (#3+#4
closed). The remaining product claims (real-IP, self-healing at scale,
real-range/throughput) are each 1-to-several milestones away — the biggest gaps
are now real IP transport (W4) and the modem's throughput/robustness ceiling.

## Competitor delta — 2026-07-08 (loop iter8)
Focused re-scan (full table in git history). Key strategic reads:
- **openwifi** (open FPGA-SDR 802.11 on Zynq+AD9361, PHY+MAC in the PL) is the
  precedent that **PHY+MAC belong in the PL** — validates W6 as the single
  highest-leverage engineering item (throughput + latency + duplex all unlock).
- **Reticulum (RNS)** is a strong but **PHY-less** stack. Angle: TRI-NET can *be*
  the RNS-class bearer (run RNS on top) rather than reinventing routing.
- **Meshtastic/goTenna** = too slow / no IP; **Silvus/Persistent** = closed,
  $10k+/radio, ITAR. TRI-NET's wedge = **open + cheap (COTS AD9361) +
  programmable-PHY IP mesh** in the gap between them. Adjacent market: the cheap
  **open bearer for ATAK/TAK**.
- Two borrowable techniques: **soft-decision FEC** (tried this iter — gated on
  modem robustness first, see A″) and **TDMA with GPS-PPS slotting** (W7) to kill
  hidden-terminal CSMA collapse.
- Top-3 skeptic attacks: (1) BPSK throughput ceiling, (2) **no PL offload** — the
  PHY is CPU-bound, (3) no published link-budget/range curve. (2) and a real
  range curve are what most convert skeptics.
