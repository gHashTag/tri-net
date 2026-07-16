# TRI-NET Phone — Wave Report v0.8 (2026-07-17)

Loop iteration. Audit → competitors → plan → implementation → report → 3 options.
Trigger: the user reported the iPhone UI was **"всё криво"** (everything crooked).
This wave centered on **making the phone UI right** (with real on-screen
verification, not guesswork) and took **Option M** from v0.7 (finish the recording).

---

## 1. Weakness audit (v0.7 → what was soft)

| # | Weakness | Severity | Evidence |
|---|----------|----------|----------|
| W7 | **In-call control bar overflowed the iPhone width** | 🔴 P0 | v0.7's blur button made it 6 fixed 56pt circles + 66pt end + gaps ≈ **430pt** vs ~337pt usable → row ran off-screen ("всё криво") |
| W8 | **iOS layout never visually verified** — fixes were blind | 🟠 P1 | no simulator/device render in the loop; the overflow shipped unseen |
| W9 | **Recording captured the remote party only** | 🟡 P2 | `CallRecorder` mixed no local mic → you don't hear yourself |

Closed all three. W7 fix was committed reactively (`472c00e`) and this wave
**visually confirmed** it. W8 is now a permanent capability (see §3). W9 = Option M.

## 2. Competitor scan (focused research)

- **In-call control bar (FaceTime / WhatsApp / Meet / Zoom mobile):** the
  universal pattern is a **single row of equal-width flexible cells**
  (`maxWidth:.infinity`), *not* fixed-pixel buttons and *not* a scroll view —
  the inter-button gap flexes, the glyph stays constant, so it fits iPhone SE →
  Pro Max. Primary bar kept to **5–6 items**; 44pt min touch target; end-call a
  distinct red. → our fix uses exactly this pattern.
- **Voice quality:** Apple's `setVoiceProcessingEnabled(true)` with
  `.playAndRecord/.voiceChat` gives **free on-device AEC + noise suppression +
  AGC** — the pragmatic default; don't stack RNNoise on top (double-processing
  artifacts). RNNoise only earns its place cross-platform (and is hardwired to
  48kHz/10ms → resampling cost). → iOS already enables VP; Mac keeps split
  engines because VPIO fails (-10875) on this hardware.
- **Recording both sides:** use **one AAC track fed by a software mix**, not two
  `AVAssetWriterInput`s (players play only one audio track). The hard part is
  two independent clocks → drift; the fix is one monotonic master clock, buffer
  the other stream, pad silence / drop to absorb drift. → M does exactly this.

## 3. Plan → shipped (v0.8)

| Item | Status | Evidence |
|------|--------|----------|
| **W8 capability — see the layout.** Boot iPhone-17-Pro simulator, render idle + call screens via `simctl` | ✅ new instrument | screenshots captured; **observability before mutation** (debugging doctrine) — no more blind UI edits |
| **W7 — control-bar overflow fix**, verified on screen | ✅ **verified** | sim render shows 6 evenly-distributed buttons (mic/flip/video/blur/chat/end) fitting the card cleanly; idle screen balanced |
| **M — mix local mic into recording** (single AAC track, remote-clocked, capped mic FIFO, clip headroom) | ✅ **algorithm PROVEN** | harness feeds a faster-than-remote mic stream → `ffprobe`: `stream,1,aac,audio` beside `h264,video`, no crash, drift/silence paths exercised |
| Both apps compile | ✅ | macOS `TriNetMonitor` Release + iOS `TriNetVideo` (device arch + simulator) all `BUILD SUCCEEDED` |

**Verification method.** Per the debugging doctrine ("observability before
mutation; don't diagnose blind"), I did **not** hand-edit the UI sight-unseen.
I stood up an iOS-Simulator render path (`simctl io screenshot`) as an
independent instrument, confirmed the idle screen was already clean, drove the
call screen via a temporary env flag (since removed), and **saw** the control
bar fit correctly after the fix. The recording mix was proven the same way it
was for J — a standalone `swiftc` harness reproducing the exact code path.

**Deployed:** Mac `TriNetMonitor` (Release) rebuilt + relaunched. **iPhone
install is pending** — the device is currently **locked**, so the developer
image won't mount; the iOS build compiles clean and the fix is verified in the
simulator (same source). Unlock the phone and it installs in one step.

Total distinct features/fixes across the phone effort: **24+**.

---

## 4. Three collaboration options for the next loop

### Option N — "Off-LAN calling" (the reach gap, carried forward)
The app still connects only two devices on the **same subnet**. Add STUN-based
NAT traversal + a thin stateless relay (sees ciphertext only) so two phones on
different networks can call. **Outcome:** works over the internet, not just the
same room — the single biggest usability unlock. **Gated on:** a public STUN
endpoint + a small relay host.

### Option Q — "Loss resilience" (smoother video on bad links)
Today packet loss → PLI → a full keyframe: bursty and bandwidth-spiky. Add
forward error correction over the video NALs (RLNC is already specced in
`tri-net/specs/rlnc_coding.t27`) so moderate loss is *corrected* without a
keyframe storm. **Outcome:** steady video on lossy Wi-Fi / cellular / radio.
**Gated on:** nothing — verifiable with packet-loss injection on this Mac.

### Option O — "Ride the radio" (the headline milestone)
Flash a second AD9361 board and run phone A/V over `trios_radiod`'s BPSK PHY —
"a video call over our own radio mesh, no cell, no Wi-Fi." `find_phy()` (v0.7)
already makes the daemon board-agnostic; the rest is hardware + the video-bridge
glue. **Outcome:** the defining TRI-NET headline, end-to-end. **Gated on:** one
more SDR board flashed.

**Recommendation:** **N** now (turns a same-room demo into a real product),
**Q** for call quality that shows on any link, **O** when the second radio is on
the bench. Also: **unlock the iPhone** so v0.8's verified fix and the recording
mix can be witnessed on-device.

---

*Anchor: φ² + φ⁻² = 3 · TRINITY*
