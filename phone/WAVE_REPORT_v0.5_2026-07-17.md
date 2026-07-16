# TRI-NET Phone — Wave Report v0.5 (2026-07-17)

Full loop: weakness audit → competitor scan → decomposed plan → implementation
→ report → three collaboration options.

---

## 1. Weakness audit (v0.4 → what was missing)

| # | Weakness | Severity | Evidence |
|---|----------|----------|----------|
| W1 | **No group call** — 1 peer, `recv()` with no source, single decoder | 🔴 P0 | Asked twice; transport held one `sockaddr_in` |
| W2 | **No recording** — competitors all have it | 🟠 P1 | No `AVAssetWriter` anywhere |
| W3 | **No jitter buffer** — audio choppy on jitter | 🟠 P1 | `playPacket` scheduled immediately, played on packet 1 |
| W4 | Screen share is macOS-only | 🟡 P2 | iOS needs a ReplayKit broadcast extension |
| W5 | No adaptive bitrate | 🟡 P2 | Fixed encoder settings |

Closed **W1, W2, W3** this wave; W4/W5 staged.

## 2. Competitor scan

- **Zoom / Meet / Teams / Jitsi** — group (100+), recording, virtual bg,
  reactions, chat. All SFU/MCU-backed for large calls.
- **Silvus StreamCaster NEXUS** — self-forming mesh, hundreds of nodes,
  ATAK/COP roster, EW-resilient.
- **Architecture research** ([Forasoft](https://www.forasoft.com/blog/article/p2p-vs-mcu-vs-sfu-for-video-conference-app-805),
  [BlogGeek](https://bloggeek.me/webrtc-multiparty-video-alternatives/)):
  **full-mesh is correct for 2–4 nodes with zero server cost**; SFU only
  pays off past ~5 participants. TRI-NET's whole thesis is *no server*, so
  full-mesh is the right call for small secure conferences.

**Takeaway:** don't build an SFU. Full-mesh broadcast + per-source decode is
both simpler and truer to the mesh thesis for the group sizes that matter here.

## 3. Decomposed plan

```
W1 Group   → connectGroup broadcast + conference key + recvfrom source + per-source decoders + roster + grid → verify: "N in call", 1-1 un-regressed
W2 Record  → AVAssetWriter of decoded frames → ~/Movies/*.mov, REC pill        → verify: valid playable .mov
W3 Jitter  → ~3-packet (~60ms) pre-roll before playback starts (both platforms) → verify: audio still plays, smoother start
```

## 4. What shipped (v0.5)

| Item | Status | Evidence |
|------|--------|----------|
| Group full-mesh transport (conference key, broadcast, recvfrom) | ✅ | `connectGroup`, per-source routing |
| Per-source decoders + roster + adaptive grid | ✅ verified | **"2 in call"** tag live |
| 1-1 forward-secret unchanged (no regression) | ✅ verified | SECURE, video, chat all still work |
| Call recording (macOS) | ✅ verified | `~/Movies/TRI-NET-*.mov`, 288px playable |
| Jitter buffer (pre-roll, both platforms) | ✅ | audio plays after ~60ms pre-roll |

**Group over 2 nodes** (real 3-way video) needs a **third camera device** to
verify end-to-end — the transport, per-source decode, roster and grid are all
in place and the 2-node case is confirmed; N>2 is code-complete, not yet
hardware-verified. Stated honestly, not claimed.

Total distinct fixes across the phone effort: **16+**.

---

## 5. Three collaboration options for the next loop

### Option G — "Prove the group" (finish W1 end-to-end)
Bring up a third camera node — a second Mac, an iPad, or a spare iPhone — and
run a real 3-way full-mesh call to verify the grid, per-source decode, and
conference-key crypto with actual concurrent streams. Add a proper roster panel
(names, mute/speaking state, à la Silvus COP) and per-tile PLI. **Outcome:** the
group feature graduates from code-complete to demonstrated. **Gated on:** one
more camera device.

### Option H — "Harden the media" (quality, unblocked)
Adaptive bitrate driven by the PLI loss signal (drop bitrate on sustained loss,
raise when clean), an adaptive jitter buffer (grow/shrink with measured jitter
instead of a fixed pre-roll), audio mixing into the recording, and a virtual
background / blur (Vision person segmentation). **Outcome:** a call that holds
up on bad Wi-Fi and recordings with sound. **Gated on:** nothing — all software,
verifiable on the two devices in hand.

### Option I — "Ride the radio" (the moat)
Flash the AD9361 SDR bitstream onto a second board so two nodes have real
radios, then bridge the phone's encrypted A/V through `trios_radiod` over the
AD9361 link instead of Wi-Fi — a phone call carried by TRI-NET's own radio mesh.
Make `trios_radiod` resolve the PHY by name (not `iio:device0`). **Outcome:**
the "call over Starlink-without-satellites" demo, the thing no Wi-Fi FPV project
can claim. **Gated on:** physical board access to flash the second SDR.

**Recommendation:** **H now** (unblocked, lifts quality across every feature),
**G when a third camera is on hand**, **I when the boards are accessible.**

---

*Anchor: φ² + φ⁻² = 3 · TRINITY*
