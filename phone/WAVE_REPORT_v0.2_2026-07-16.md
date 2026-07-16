# TRI-NET Phone — Wave Report v0.2 (2026-07-16)

Full loop: weakness audit → competitor scan → decomposed plan → implementation
→ report → three collaboration options for the next loop.

---

## 1. Weakness audit (v0.1.0 → what was missing)

Ranked by severity. Each is a real gap found by reading the shipped code, not a hypothetical.

| # | Weakness | Severity | Why it matters |
|---|----------|----------|----------------|
| W1 | **No encryption** — plaintext H.264 on UDP :7000 | 🔴 P0 | Any device on the LAN could watch the call or inject frames. Fatal for a product whose thesis is *secure* mesh. |
| W2 | **No audio** — video-only | 🔴 P0 | A "video call" without voice is a demo, not a call. |
| W3 | **Single-slot fragment reassembler** | 🟠 P1 | Interleaved NALs (video + peer restart) corrupted each other's partial buffers. |
| W4 | **No mute on Mac / no camera-off symmetry** | 🟡 P2 | Basic call-control parity. |
| W5 | Static PSK, no per-node key exchange | 🟡 P2 | Fine for MVP, but real deployment needs the mesh handshake. |
| W6 | No loss concealment / jitter buffer | 🟢 P3 | UDP drops show as green/pink smears; acceptable for LAN, not for RF. |
| W7 | Bitrate/resolution not adaptive | 🟢 P3 | Fixed 640×480 / 288×352; no congestion response yet. |

**This wave closed W1, W2, W3, W4.** W5–W7 are staged for the next loop (see §5).

---

## 2. Competitor scan

Where TRI-NET Phone sits versus the field. Sources are open web (July 2026).

### Open-source FPV / drone video links
- **OpenHD**, **RubyFPV**, **WFB-ng** — raw-WiFi broadcast HD video for drones, 2.4/5.8 GHz, Raspberry-Pi/SBC class. OpenHD multiplexes HD video + MAVLink + RC through one pipeline, 50 km+ range. **Broadcast, one-way (air→ground), no encryption by design, no voice.** TRI-NET's duplex + encryption + voice is a different shape; their RF range and maturity are far ahead.
- **Takeaway:** don't compete on FPV range. TRI-NET's edge is *bidirectional encrypted A/V as an app*, portable across phone + FPGA node, not a ground-station.

### Tactical MANET radios
- **Silvus StreamCaster** (Motorola) — MN-MIMO waveform, hundreds of nodes, EW-resilient, 100 Mbps, the MINI 5200 is 182 g / 2 W. Carries video/voice/data over self-forming mesh. **Proprietary hardware + waveform, defense-priced.**
- **Takeaway:** Silvus *is* the incumbent TRI-NET's drone-mesh thesis targets. TRI-NET's differentiator is the published, auditable protocol on commodity FPGA (Artix-7/Zynq) vs. a closed waveform. The phone app is the human-facing demo of that stack.

### Consumer P2P (WebRTC on LAN)
- WebRTC does encrypted P2P A/V and, on a LAN, connects without STUN/TURN — but still needs a **signaling channel** (SDP/ICE exchange) and has **no fallback if the direct path fails**. It is browser/heavyweight and assumes IP infrastructure.
- **Takeaway:** TRI-NET Phone's zero-signaling, fixed-port, raw-UDP model is *simpler* than WebRTC for a known-peer mesh and drops straight onto a radio link where WebRTC's ICE assumptions break. That is the niche: **infrastructure-free, known-peer, encrypted A/V that ports onto mesh radio.**

**Positioning in one line:** *not an FPV link, not a $10k radio, not browser WebRTC — an infrastructure-free encrypted video+voice app that runs on a phone today and is designed to ride the TRI-NET FPGA mesh tomorrow.*

---

## 3. Decomposed plan (this wave)

```
P0 W1 Encryption   → ChaChaPoly seal/open, PSK=SHA256(secret), both transports  → verify: foreign pkt dropped, own decodes
P0 W2 Audio        → AudioController 16k PCM/UDP, AEC, mute wire, both platforms → verify: audio tx/rx logs, hear voice
P1 W3 Reassembler  → multi-slot dict keyed by seq + GC                           → verify: still decodes under load
P1 W4 Mute (Mac)   → mic button in Monitor InCallView                            → verify: button toggles isMuted
Ship  Release      → Release builds, /Applications + iPhone, tag, report         → verify: live duplex
```

---

## 4. What shipped (v0.2.0)

| Item | Status | Evidence |
|------|--------|----------|
| ChaCha20-Poly1305 on every datagram (both sides) | ✅ | Video still decodes (⇒ decrypt OK); no `dropped` flood |
| Audio Mac → iPhone | ✅ verified | Console: `audio tx 2722B` (Mac) / `audio rx 2720B` (iPhone) |
| Audio iPhone → Mac | ⏳ pending user | Needs Start-Call tap + mic-permission grant on the phone |
| Voice-processing AEC with fallback | ✅ | Mac VPIO failed on 9-ch device (−10875) → auto-rebuilt ch=1, works |
| iOS mic-permission request | ✅ | Added; grants then restarts audio |
| Multi-slot fragment reassembly | ✅ | Duplex video stable |
| Mute button on Mac + iPhone | ✅ | Wired to `isMuted`, drops packets at source |
| Encrypted duplex **video** | ✅ verified | `FIRST FRAME DECODED` both sides, live on screen |

**Bug count across the whole phone effort: 10 fixed** (IPv6-only NWListener ×2, SPS/PPS one-shot ×2, Annex-B start-code ×2, layer/display ×2, fixed profile-level, UDP 9216-byte datagram cap). v0.2 added encryption + audio on top with no video regression.

### Known remaining (next loop)
- iPhone→Mac audio needs the on-device Start+permission (can't be driven from here).
- Static PSK — swap for trios-mesh per-node key exchange (W5).
- No jitter buffer / FEC (W6), no adaptive bitrate (W7).

---

## 5. Three collaboration options for the next loop

### Option A — "Make it a real call" (product-hardening)
Jitter buffer + packet-loss concealment, adaptive bitrate on congestion, call-setup UX (ring/accept instead of auto-start), background-audio session. **Outcome:** a call that survives real Wi-Fi and feels like FaceTime. **Effort:** ~1 loop. **Best if** the goal is a demoable consumer-grade app.

### Option B — "Put it on the mesh" (integration with TRI-NET stack)
Replace the static PSK with the trios-mesh B'-wire authenticated handshake (per-node forward-secret keys), route A/V through the `MeshRouter` 10.42.0.0/24 data plane instead of a direct IP, and run a 3-node relay so the phone talks to the far phone *through* a middle FPGA node. **Outcome:** the phone becomes the human-facing demo of "Starlink without satellites." **Effort:** ~2 loops. **Best if** the goal is the investor/partner story.

### Option C — "Prove it on radio" (hardware bring-up)
Cross-compile the transport to the P201Mini (armv7), carry the encrypted A/V datagrams over the AD9361 BPSK PHY instead of Wi-Fi UDP, and measure latency/throughput over the air between two boards. **Outcome:** first end-to-end video-over-own-radio, the milestone that separates TRI-NET from every Wi-Fi FPV project. **Effort:** ~2–3 loops, hardware-gated. **Best if** the goal is the defensible technical moat.

**Recommendation:** **B**, then **C**. B reuses proven mesh crypto (closes W5 properly) and produces the headline demo; C is the moat but is hardware-gated and benefits from B's routing already in place. A is worthwhile but is polish that can trail the story.

---

*Anchor: φ² + φ⁻² = 3 · TRINITY*
