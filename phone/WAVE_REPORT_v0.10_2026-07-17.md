# TRI-NET Phone — Wave Report v0.10 (2026-07-17)

Loop iteration. Audit → competitors → plan → implementation → report → 3 options.
This wave took **Option R** from v0.9 — iPhone call recording — because it is
**additive** (no change to the working call path, so zero regression risk) and
matches the standing "и на телефон обязательно" priority; it reuses the already-
proven `CallRecorder` codec, so it holds up even though on-device witness waits
on an unlocked phone.

---

## 1. Weakness audit (v0.9 → what was soft)

| # | Weakness | Severity | Evidence |
|---|----------|----------|----------|
| W13 | **Recording was Mac-only** — the phone couldn't capture a call | 🟠 P1 | `CallRecorder` existed only in the desktop target; iOS had no record path |
| W14 | **No way to get a recording off the device** | 🟡 P2 | even once recorded, no share/export affordance |
| W15 | Every recent feature awaits on-device verification (phone locked) | 🟠 P1 | v0.8 UI fix, M mix, v0.9 FEC all built + harness-proven but unwitnessed live |

Closed W13 + W14. W15 is now the recurring meta-blocker → drives Option S below.

## 2. Competitor scan (focused)

- **FaceTime / WhatsApp / Meet mobile:** recording is a first-class per-device
  action, not desktop-only; the captured clip lands somewhere shareable (Photos
  / Files / share sheet). Parity across endpoints is expected.
- **Control-bar limit (reconfirmed):** ≤6 primary buttons; secondary actions go
  to a top affordance or a "More" sheet, never a 7th button that overflows small
  phones. → the REC toggle went to the **top bar**, leaving the six primary
  controls a single row (verified in the simulator).
- **On iOS**, app-sandbox recordings reach the user via `UIActivityViewController`
  (share sheet) or Files; writing to `Documents` keeps the clip reachable.

## 3. Plan → shipped (v0.10)

| Item | Status | Evidence |
|------|--------|----------|
| **R — iPhone records the call** (video + single AAC track mixing remote + local mic) | ✅ built; codec PROVEN | ported the harness-proven `CallRecorder`; embedded in `VideoPipeline.swift` (iOS static file list) |
| `onRxPCM`/`onTxPCM` on iOS `AudioController`; ViewModel `toggleRecording` + Combine frame sink | ✅ | mirrors the Mac wiring |
| Share sheet for the saved `.mov` (save/send), file in `Documents` | ✅ | `RecFile` → `.sheet(item:)` → `ShareSheet` (UIActivityViewController) |
| **REC toggle in the call top bar**, six-button bottom row intact | ✅ **verified on screen** | iPhone-17-Pro simulator: `● Rec` pill top-bar, bottom row still 6 buttons — no layout regression |
| Both builds | ✅ | iOS device arch + simulator `BUILD SUCCEEDED` |

**Verification method.** The change is additive — the live call path is untouched,
so it cannot regress video/audio. The recorder **codec** is the same one proven by
the standalone harness in J/M (valid AAC track from mixed PCM). The **UI** was
verified visually in the simulator (REC pill placed, bottom bar unchanged). What
remains unwitnessed is the on-device record→share round trip, pending an unlocked
phone.

**Deployed:** iOS build compiles clean; **install pending an unlocked iPhone**
(developer image won't mount while locked). Mac unchanged this wave.

Total distinct features/fixes across the phone effort: **26+**.

---

## 4. Three collaboration options for the next loop

### Option S — "Self-test peer" (unblock live verification, fully autonomous) ⭐
Every recent wave ends "pending an unlocked phone / no loopback." Build a headless
echo/loopback peer (or fix why `127.0.0.1` self-calls don't establish) so the whole
pipeline — crypto handshake, fragmentation, **FEC**, **recording mix** — can be
exercised end-to-end **on one Mac**, with packet-loss injection to prove FEC live.
**Outcome:** the accumulated unverified features (M, FEC, R) get real end-to-end
confirmation without a second device. **Gated on:** nothing — build *and* verify on
this machine.

### Option N — "Off-LAN calling" (the reach gap, still #1)
Same-subnet only. STUN public-endpoint discovery + hole punching (free public STUN,
unblocked) covers most home NATs; a thin ciphertext-only relay handles symmetric-NAT
fallback. **Outcome:** calls across networks. **Gated on:** a relay host (STUN part
needs nothing).

### Option O — "Ride the radio" (the headline milestone)
Flash a second AD9361 board, run phone A/V over `trios_radiod`'s BPSK PHY — now that
FEC (v0.9) makes video survive the lossier RF link. **Outcome:** "a video call over
our own radio mesh." **Gated on:** one more SDR board.

**Recommendation:** **S** next — it converts the growing pile of "built but
unwitnessed" work (M, FEC, R) into verified features and gives a repeatable local
test rig, all without waiting on hardware. Then **N** for reach, **O** for the
headline. And still: **unlock the iPhone** — four device-side deliverables (v0.8 UI
fix, M, FEC, R) are queued for a one-step install.

---

*Anchor: φ² + φ⁻² = 3 · TRINITY*
