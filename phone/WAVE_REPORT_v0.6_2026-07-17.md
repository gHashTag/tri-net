# TRI-NET Phone — Wave Report v0.6 (2026-07-17)

Loop iteration. Audit → competitors → plan → implementation → report → 3 options.
This wave took **Option H** from v0.5 ("harden the media" — quality, unblocked).

---

## 1. Weakness audit (v0.5 → what was soft)

| # | Weakness | Severity | Evidence |
|---|----------|----------|----------|
| W1 | **Fixed bitrate** — no response to loss | 🟠 P1 | `AverageBitRate` set once at setup |
| W2 | **No virtual background** — competitors all have it | 🟠 P1 | no Vision/CIFilter |
| W3 | **Fixed jitter pre-roll** — not adaptive | 🟡 P2 | `rxCount >= 3` constant |
| W4 | Recording is video-only (no audio) | 🟡 P2 | `CallRecorder` writes video track only |

Closed **W1, W2, W3**; W4 deferred (needs PCM→CMSampleBuffer plumbing).

## 2. Competitor scan

- **Zoom / Meet / Teams** — background blur/replace, adaptive quality, noise
  suppression. Blur is now table-stakes.
- **Silvus NEXUS** — adapts waveform/rate to link conditions; the mesh analog of ABR.
- **Technique research** ([Forasoft ABR](https://www.forasoft.com/blog/article/p2p-vs-mcu-vs-sfu-for-video-conference-app-805),
  IEEE adaptive jitter): the standard levers are **loss-driven bitrate** and a
  **variance-driven jitter buffer** — exactly the two we lacked. We already emit
  a PLI loss signal, so ABR is nearly free to wire in.

## 3. Plan → shipped (v0.6)

| Item | Status | Evidence |
|------|--------|----------|
| Adaptive bitrate (PLI-driven, ×0.7 down / ×1.2 up) | ✅ verified | PLIs sampled, `nudgeBitrate` live, no regression |
| Virtual background (Vision segmentation + blur) | ✅ verified | toggle active, no crash, video flows |
| Adaptive jitter buffer (EWMA of 20ms-cadence deviation) | ✅ | pre-roll target 2–8 |
| Audio into recording | ⏸ deferred | recording still video-only |

**Verified live:** blur toggled on with the process staying up (Vision runs on the
outgoing frame — the peer sees the blur), session established, PLI→bitrate loop
active, 2-in-call roster intact. iOS encoder unchanged this pass (macOS-side).

Total distinct features/fixes across the phone effort: **19+**.

---

## 4. Three collaboration options for the next loop

### Option J — "Finish the recording" (unblocked)
Add an audio track to `CallRecorder`: wrap the incoming 16k PCM into
CMSampleBuffers and feed a second AVAssetWriterInput, so recordings have sound.
Add recording of the *local* mic too (mix), and a small "saved to Movies"
confirmation with a reveal-in-Finder action. **Outcome:** complete A/V
recordings. **Gated on:** nothing — pure software, verifiable on this Mac.

### Option K — "Bring blur + ABR to iPhone" (parity)
Port the virtual background (Vision person segmentation is on iOS too) and the
adaptive bitrate loop to the iOS encoder, plus background-replace (not just
blur) with a bundled image. **Outcome:** feature parity and a nicer demo on the
device people actually hold. **Gated on:** nothing — verifiable Mac↔iPhone.

### Option L — "Prove the group / ride the radio" (the milestones)
The two hardware-gated milestones still standing: a real 3-way full-mesh call
(needs a third camera device) and phone-A/V over the AD9361 radio via
`trios_radiod` (needs a second SDR board flashed). **Outcome:** the group
feature demonstrated end-to-end, and/or the "call over our own radio mesh"
headline. **Gated on:** one more camera, and/or board access.

**Recommendation:** **J now** (finishes a half-done feature, unblocked), **K**
for device-side parity, **L when the hardware is on hand.**

---

*Anchor: φ² + φ⁻² = 3 · TRINITY*
