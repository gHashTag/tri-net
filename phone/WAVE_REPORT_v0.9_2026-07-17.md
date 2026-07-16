# TRI-NET Phone — Wave Report v0.9 (2026-07-17)

Loop iteration. Audit → competitors → plan → implementation → report → 3 options.
This wave took **Option Q** from v0.8 — loss resilience — because it is the one
option verifiable **autonomously** right now (the iPhone is locked and there is no
loopback path, so anything needing two live endpoints can't be end-to-end tested
this loop; a pure codec can).

---

## 1. Weakness audit (v0.8 → what was soft)

| # | Weakness | Severity | Evidence |
|---|----------|----------|----------|
| W10 | **A single lost fragment stranded a whole I-frame** | 🟠 P1 | `reassemble` needs all `total` fragments; one loss → `have < total` forever → decode error → PLI → **keyframe storm** on lossy links |
| W11 | Loss recovery was retransmit-only (keyframe request), no FEC | 🟠 P1 | only lever was `0xFC` PLI → new IDR (big, bandwidth-spiky) |
| W12 | Off-LAN calling still absent | 🔴 P0 | same-subnet only (carried: Option N) — blocked on a relay host this loop |

Closed W10 + W11 with forward error correction. W12 stays the top open gap.

## 2. Competitor scan (focused)

- **WebRTC / Zoom / Meet / tactical radios** all pair retransmit-based recovery
  (NACK/PLI) with **forward error correction** so light loss is *corrected in
  place* instead of triggering a costly keyframe. FEC trades a little steady
  bandwidth for far smoother video on lossy Wi-Fi / cellular / RF.
- The canonical low-cost scheme is **XOR parity over a block of N packets**
  (SMPTE 2022-1 / FECFRAME): 1 parity packet recovers any single loss in the
  block; overhead = 1/N. Reed–Solomon / RLNC recover multiple losses at higher
  cost — a natural next step, not needed for the common single-loss case.
- Our fragmentation already groups an I-frame into N fragments with a shared
  sequence, so a per-group XOR parity was a near-free fit — no new framing.

## 3. Plan → shipped (v0.9)

| Item | Status | Evidence |
|------|--------|----------|
| **Q — XOR-FEC parity** per fragmented NAL (`0xFA 0xEC`; cells padded to 1200B, last-cell length in header) | ✅ **codec PROVEN** | standalone harness **70/70**: single-loss recovery at every fragment position (incl. short last cell) over 2..50-fragment payloads, no-loss passthrough, two-loss *not* falsely reconstructed |
| Receiver rebuilds any single lost fragment without a keyframe; 2+ losses fall back to PLI | ✅ | `tryFEC()` triggers on both fragment and parity arrival; additive |
| Mirrored on both transports, wire-compatible | ✅ | `MeshTransport.swift` + `VideoPipeline.swift`, identical format |
| Backward-safe (old peers ignore `0xFA 0xEC`) | ✅ | new magic; existing path untouched |
| Both apps compile | ✅ | macOS Release + iOS (device arch) `BUILD SUCCEEDED` |

**Verification method (debugging doctrine).** With no two-endpoint test available
this loop, I proved the **codec** the same way as J and M — a standalone `swiftc`
harness reproducing the exact `send`/`reassemble`/`tryFEC` code paths, asserting
byte-identical recovery across positions and sizes, and asserting it does *not*
falsely reconstruct under multi-loss. The change is deliberately **additive**:
parity is extra packets under a new magic, the working data path is byte-for-byte
unchanged, so it cannot regress video even though the live two-device run is
still pending an unlocked phone.

**Deployed:** Mac `TriNetMonitor` (Release) rebuilt + relaunched. **iPhone install
pending unlock** (developer image won't mount on a locked device); the iOS build
compiles clean and the codec is proven.

Total distinct features/fixes across the phone effort: **25+**.

---

## 4. Three collaboration options for the next loop

### Option N — "Off-LAN calling" (the reach gap, still #1)
Same-subnet only today. The STUN half (public-IP/port discovery + hole punching
against free public STUN servers) is **unblocked** and handles most home NATs;
add a thin stateless relay (ciphertext-only) for symmetric-NAT fallback.
**Outcome:** calls across different networks, not just the same Wi-Fi.
**Gated on:** a relay host for the fallback (STUN part needs nothing).

### Option R — "iPhone records too" (parity)
Recording is Mac-only. Port the proven `CallRecorder` (video + mixed audio, J+M)
to iOS with `AVAssetWriter`, plus a share-sheet to save/send the `.mov`.
**Outcome:** either end can capture the call; a shareable artifact on the device
people actually hold. **Gated on:** nothing (codec verifiable by harness); a live
witness needs the phone unlocked.

### Option O — "Ride the radio" (the headline milestone)
Flash a second AD9361 board and run phone A/V over `trios_radiod`'s BPSK PHY —
now doubly worth it since FEC makes video survive the lossier RF link.
`find_phy()` already made the daemon board-agnostic. **Outcome:** "a video call
over our own radio mesh." **Gated on:** one more SDR board.

**Recommendation:** **N** now (turns a same-room demo into a product), **R** for
device parity, **O** when the second radio is on the bench — FEC (this wave) is
exactly what makes the radio path viable. Also: **unlock the iPhone** so v0.8's
UI fix, the recording mix (M), and FEC can be witnessed live on-device.

---

*Anchor: φ² + φ⁻² = 3 · TRINITY*
