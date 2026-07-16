# TRI-NET Phone — Wave Report v0.3 "All Three" (2026-07-16)

The previous loop offered three collaboration options (A product-hardening,
B mesh-integration, C radio bring-up). The user chose **all three**. This wave
implemented A and B in full (verified live), and took C onto real FPGA hardware
where it revealed a precise hardware-config blocker.

---

## A — Loss recovery ✅ shipped & verified

The duplex return channel (both peers already send and receive on :7000) is now
used as a feedback path, RTCP-style:

- **Wait-for-IDR:** after a session (re)start or an SPS change the decoder skips
  P-frames — which reference a keyframe it never received — until a real IDR
  arrives, instead of decoding them into garbage.
- **Picture Loss Indication (PLI):** on a gap the receiver sends a 2-byte `0xFC`
  control packet; the sender forces the next frame to an IDR
  (`kVTEncodeFrameOptionKey_ForceKeyFrame`). Verified: `forcing keyframe (peer
  PLI)` logged on both Mac and iPhone.
- **Tuning:** an early version forced a keyframe on *every* decode failure,
  which — because a single dropped P-frame fails normally on lossy UDP — caused
  a **PLI storm**. Corrected: a lone P-frame drop resyncs on the 0.5 s keyframe
  cadence; PLI fires only on real desync (start / SPS change).

Call UX (ring/accept) was scoped out in favor of the loss-recovery engine — it
needs a call-setup signaling exchange that overlaps with the mesh work (B/next
loop) and is polish, not a technical gap.

## B — Forward-secret handshake ✅ shipped & verified

v0.2 encrypted data directly under a static PSK — a PSK leak would decrypt all
past recordings. v0.3 replaces that with a real handshake, mirroring
`trios-mesh/src/crypto.rs`:

```
ephemeral X25519  →  HKDF(salt "trios-mesh/v1/session", info "aead-key")  →  ChaCha20-Poly1305
```

- The ephemeral public key is authenticated by the PSK (HMAC-SHA256), so a
  passive LAN attacker can't MITM without the PSK.
- **Forward secrecy:** ephemeral private keys are never persisted, so a PSK
  leaked *later* can't decrypt recorded traffic. The static PSK is demoted to a
  handshake authenticator only.
- Both transports beacon the handshake every 250 ms until a session is up; data
  is dropped until then. Verified live: `session established (forward-secret)`
  on **both** sides, followed by encrypted duplex video (screenshot: sharp
  upright portrait video, `Connected`).
- **Bug found & fixed:** the handshake timer was scheduled on `rxQueue`, which
  is parked forever inside a blocking `recv()` — so it never fired and no
  session ever formed (traffic 0/0). Moved to a dedicated `hsQueue`.

This is the phone-side analog of trios-mesh's B'-wire authenticated handshake.
The next step (real per-node identity keys instead of a shared PSK) is the
mesh-integration item carried forward.

## C — trios-mesh over real radio ⚙️ on hardware, blocked on SDR config

Took the actual mesh daemon onto the physical Zynq boards:

- **Cross-compiled** `trios_radiod` for `armv7-unknown-linux-musleabihf`
  (static musl ELF, 645 KB, stripped) with the host `cargo zigbuild` toolchain.
- **Ran on real silicon:** deployed to board **.13** (P201 pzp201mini,
  ARMv7 Linux 5.10) — it came up with a **real forward-secret identity key**
  (W3b), BPSK modulation, `radio_setup` writing the AD9361 LO/gain over libiio,
  and the mesh router active. Second node started on **.12** as receiver.
- **Both nodes ran over the air** — beaconing, mesh routing live — but never
  heard each other: `neighbors { peer = inf }`, and the test send returned
  `TX test -> 12: Dropped(NoRoute)`.

**Root cause (found, not guessed):** only board **.13** has a fully
initialized AD9361 in IIO — `iio:device0 = ad9361-phy`, `device2 =
cf-ad9361-dds-core-lpc`. Boards **.11 / .12** enumerate **only** `iio:device0 =
xadc` — the AD9361 SDR is not loaded (no FPGA bitstream / device-tree overlay
for `cf-ad9361`). `trios_radiod` hard-codes `PHY = iio:device0`, so on .12 its
LO/gain writes land on `xadc` and silently no-op; the radio is never tuned, so
beacons don't transmit.

A two-node over-the-air link needs a **second board with a loaded AD9361
bitstream** — a hardware-provisioning step (flash the SDR image), not a code
change, and one that needs physical access to the boards. What *is* proven this
loop: the mesh stack cross-compiles, runs, and self-secures on the real ARM
node; the blocker is isolated to SDR bring-up on the peer board.

Logs: `phone/artifacts/radiod13.log`, `radiod12.log`.

---

## Status matrix

| Capability | v0.1 | v0.2 | v0.3 |
|-----------|------|------|------|
| Duplex encrypted video | ✅ | ✅ | ✅ |
| Two-way audio | — | ✅ (Mac→iPhone verified) | ✅ |
| Encryption | — | static PSK | **forward-secret X25519** |
| Loss recovery | — | — | **wait-for-IDR + PLI** |
| Camera switching | ✅ | ✅ | ✅ |
| Mesh over own radio | — | — | ⚙️ daemon runs on HW; SDR peer unprovisioned |

Total distinct bugs fixed across the phone effort: **13** (v0.3 added the
handshake-timer-on-blocked-queue bug and the PLI storm).

---

## Three collaboration options for the next loop

### Option D — "Second radio node" (finish C)
Flash the AD9361 SDR bitstream + device-tree overlay onto board .12 (or .11) so
it enumerates `cf-ad9361`, then rerun the two-node over-the-air test that is
already staged and cross-compiled. Also make `trios_radiod` resolve the PHY by
**name** (`ad9361-phy`) instead of hard-coded `iio:device0`, so it's robust to
board-to-board device ordering. **Outcome:** first end-to-end mesh packet over
TRI-NET's own radio — the milestone that separates it from every Wi-Fi FPV
project. **Gated on:** physical board access to flash the second SDR.

### Option E — "Phone rides the radio" (bridge A/B ↔ C)
Bridge the phone app to `trios_radiod`: the Mac sends its encrypted A/V
datagrams to board .13 over Ethernet, radiod carries them over the AD9361 to a
second node, which hands them to the far phone. The phone's forward-secret
session (B) rides *inside* the mesh's own crypto — two independent secure
layers. **Outcome:** the headline "phone call over Starlink-without-satellites"
demo. **Gated on:** Option D first (needs the second radio node).

### Option F — "Make the call production-grade" (pure software, unblocked)
Jitter buffer + adaptive bitrate driven by the PLI signal we now have (PLI rate
is a live loss estimate → drop bitrate on sustained loss, raise it when clean),
real per-node identity keys replacing the shared PSK (closes the last MITM gap
in B), and call-setup UX (ring/accept). **Outcome:** a call that survives real
Wi-Fi and a security model with no shared secret. **Gated on:** nothing — all
software, runs on the hardware in hand today.

**Recommendation:** **F now, D+E when the boards are physically accessible.** F
is unblocked, hardens both A and B, and its adaptive-bitrate work reuses the PLI
channel just built. D unblocks the radio milestone but needs someone at the
bench to flash the second SDR; E follows D.

---

*Anchor: φ² + φ⁻² = 3 · TRINITY*
