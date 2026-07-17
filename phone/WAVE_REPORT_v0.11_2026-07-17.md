# TRI-NET Phone — Wave Report v0.11 (2026-07-17)

Loop iteration. Audit → competitors → plan → implementation → report → 3 options.
This wave did **not** start a new feature. Two user-reported breakages were open
(video freezing, then audio dead), both traceable to my own changes, so the wave
went to diagnosis and repair — and to recording an honest post-mortem of how the
process let them through.

---

## 1. Weakness audit

| # | Weakness | Severity | Evidence |
|---|----------|----------|----------|
| W16 | **Audio from the phone dies after ~2 buffers** | 🔴 P0 | live log: `audio rx #1 3200B`, `#2 3200B`, then nothing, while `rx #500` of video kept flowing |
| W17 | **Zero audio-notification handling on either platform** | 🔴 P0 | `grep NotificationCenter` → **0** hits in both `AudioController`s; AVAudioEngine drops taps on reconfiguration and nothing rebuilt them |
| W18 | **Audio packets violated the documented never-fragment invariant** | 🟠 P1 | code says "~20ms per packet … never fragmented"; reality was **3178–3200B** (100ms) vs `maxPayload` 1200 |
| W19 | **My observability was a broken ruler** | 🔴 P0 | the log redirect captured `open`'s stderr, not the app's → audio telemetry was invisible for the whole project |
| W20 | **Process: I ship transport changes I cannot verify end-to-end** | 🔴 P0 | three straight bugs (FEC skew, audio fragmentation, audio-graph death) were found by the **user**, not by me |

## 2. Competitor / best-practice scan

- Handling **`AVAudioEngineConfigurationChange`** is not optional for any serious
  VoIP app: the engine stops and *every installed tap is dropped* when the graph
  is reconfigured (route settling, voice processing re-tuning the I/O, hardware
  change). FaceTime-class apps rebuild the graph on that notification.
- iOS VoIP apps must additionally handle **interruption** (call/alarm),
  **route change**, and **`mediaServicesWereReset`** (the whole audio stack dies
  and must be rebuilt from scratch).
- **`setVoiceProcessingEnabled(true)` re-tunes the input chain**, so the input
  format must be re-read afterwards — a converter/tap built on a stale format is
  a classic silent-mic bug.
- VoIP payloads are conventionally **10–20ms per packet** precisely so a voice
  datagram never fragments; ours were 100ms and did.

## 3. Plan → shipped (v0.11)

| Item | Status | Evidence |
|------|--------|----------|
| **Real observability** — launch the binary directly so NSLog lands on a stderr we own | ✅ | first time the audio telemetry was ever visible; it immediately produced the diagnosis |
| **20ms audio slicing** — restore the never-fragment invariant | ✅ **verified live** | `audio tx first packet 642B` (was 2722B) |
| **Rebuild the audio graph on configuration change** (both platforms) + iOS interruption / route / mediaServicesReset recovery | ✅ built | idempotent `buildAndStart`, format re-read after VP, pre-roll re-armed, observers torn down in `stop()` |
| Reassembly GC by recency instead of "keep only the current seq" | ✅ (latent fix, **not** the cause) | kept because the old GC was genuinely destructive |
| FEC parity send gated off; unknown `0xFA` subtypes dropped, not decoded | ✅ (v0.10.1) | fixed the video freeze |

### Refuted hypothesis (recorded deliberately)

I theorised the destructive GC was starving audio. The log **refuted it**:
`frag GC dropped: 0` — it never fired once. And had the phone still been sending
audio fragments that failed to reassemble, `fragBufs` would have filled and
tripped the GC; it did not. Therefore the peer *stops sending* audio, which
redirected the search to the capture graph and found W17. The GC fix stays as a
latent-bug fix, but it is **not** credited with this symptom.

### Post-mortem: how two regressions shipped

- The FEC break came from asserting "additive, ignored by old peers" that I never
  tested against a real old peer — while the phone sat on an old build because
  installs kept failing. **Asymmetric deploy + an untested safety claim.**
- The audio bug was invisible because my only instrument was reading the wrong
  stderr — the **broken-ruler error**, the exact failure the project doctrine was
  written about.

**Deployed:** Mac rebuilt + relaunched with live log capture. **iPhone not
updated** — it was locked, and is now off the network entirely
(`CoreDeviceService … unable to locate a device`), so the audio-graph fix is
**unverified on the device**.

---

## 4. Three collaboration options for the next loop

### Option S — "Two endpoints on one Mac" (the systemic fix) ⭐
Three consecutive bugs were found by you, not me, for one reason: I cannot run
both ends. Build a real test rig — run the **iOS app in the Simulator as the
second endpoint** (same iOS transport/audio code, full stderr via `simctl`), with
configurable ports so simulator and Mac coexist on one host, plus packet-loss
injection. **Outcome:** audio/video/FEC/recording verified end-to-end before you
ever see them, and today's audio fix confirmed. **Gated on:** nothing.

### Option T — "Audio watchdog + health surfaced" (defense in depth)
Even with the rebuild, a silent mic should never be silent *invisibly*. Add a
watchdog: if no capture buffer arrives for >1s mid-call, log it and rebuild; show
audio health in the HUD (mic alive / last buffer age) so a dead tap is visible in
one glance instead of via a bug report. **Outcome:** this class of failure
self-heals and is observable. **Gated on:** nothing.

### Option N — "Off-LAN calling" (the reach gap)
Still same-subnet only. STUN discovery + hole punching (unblocked) covers most
home NATs; a thin ciphertext-only relay handles symmetric NAT. **Outcome:** calls
across networks. **Gated on:** a relay host.

**Recommendation:** **S first** — the honest lesson of the last three waves is
that the bottleneck is not features, it's that I have no way to test a call. S
fixes that and retroactively validates M, FEC, R and today's audio fix. Then
**T**, then **N**.

**Needed from you:** bring the iPhone back on the network and unlock it — it is
currently unreachable, so five device-side deliverables (v0.8 UI fix, M, FEC gate,
R, and this audio fix) are all queued behind a one-step install.

---

*Anchor: φ² + φ⁻² = 3 · TRINITY*
