## Goal
Create standalone repo `gHashTag/trios-mesh` and land **Milestone 1**: X25519 handshake + ChaCha20-Poly1305 AEAD running **on-device** on a real Zynq-7020 Mini ARM-Linux node, graduating the sim-only unit tests.

## Context
**Honest status:** `trios-mesh` does NOT exist — confirmed `gh repo view gHashTag/trios-mesh` = *Could not resolve to a Repository*; zero mesh/routing/crypto code anywhere under `trinity` (the only ChaCha20 hit is the TLS cipher-suite string `"TLS_CHACHA20_POLY1305_SHA256"` in `src/mcp/tls_manager.zig:63`, unrelated; X25519 appears only in the Zig build cache as std-lib artifacts, not source). Crypto currently exists only as **sim-only Zig std unit tests on the host** `[-sim]`.

Board: **P201/P203 Mini** (XC7Z020, dual Cortex-A9 + AD9361/AD9363 SDR, 1x GbE, boots ARM-Linux from SD). This is the flying MVP node; the daemon runs on its PS (ARM) side, not on RTL. This M1 is a **crypto-on-ARM** milestone — the SDR radio is NOT involved (no PHY, no range claims; note the onboard PA is only 10-15 dBm and needs an external PA+LNA for any real link, but that is out of scope here). **Why now:** FPGA hardware is physically connected, `p0-mini-boot` brings ARM-Linux up from SD, so for the first time there is a real Cortex-A9 target to cross-compile to and run crypto on — not the host sim.

Repo placement: **standalone repo**, NOT inside `trinity` (strict std-only Zig monolith, zero-deps — a TUN/TAP networking daemon doesn't fit) and NOT in `trinity-fpga` (RTL/bitstream infra). This `trinity-fpga` issue is the drone-mesh EPIC tracker; code home is separate. Cross-link from the EPIC.

## Tasks
- [ ] Create repo `gHashTag/trios-mesh` (Apache-2.0) with dirs: `routing/` `crypto/` `discovery/` `daemon/` `tests/` `smoke/`
- [ ] Migrate existing sim-only crypto unit tests into `tests/` (host-run, keep green as regression baseline)
- [ ] `crypto/`: X25519 ephemeral ECDH per-neighbor + HKDF session-key derivation; static identity key for node auth; rekey policy
- [ ] `crypto/`: ChaCha20-Poly1305 AEAD per datagram — 96-bit nonce (counter+direction, **never reused**), replay window, MTU-aware framing
- [ ] Wire cross-compile target for the Mini PS — 32-bit ARM (Cortex-A9, `xc7z020` PS) — real toolchain, real sockets, no host-only assumptions
- [ ] `smoke/`: M1 harness — two processes complete an X25519 handshake over a socket and exchange AEAD-sealed frames **on the Mini's ARM-Linux**
- [ ] Run M1 on the real Mini node (from `p0-mini-boot`): handshake completes + AEAD encrypt/decrypt round-trips on-device
- [ ] Record M1 result (device, kernel/uname, throughput/latency of the AEAD loop) in repo `smoke/M1_RESULTS.md`
- [ ] Cross-link: add `trios-mesh` repo reference to the drone-mesh EPIC in `gHashTag/trinity-fpga`

## Acceptance criteria
- `gh repo view gHashTag/trios-mesh` resolves; six dirs present; Apache-2.0 LICENSE.
- Host `tests/` pass (migrated sim baseline) — still green `[-sim]`.
- Cross-compiled binary runs on the Mini as a 32-bit ARM (Cortex-A9) build (`uname -m` typically `armv7l`, per whatever SD Linux image `p0-mini-boot` produces — record the actual value rather than gating on a hardcoded string).
- **On real Mini ARM-Linux:** X25519 handshake derives a matching session key on both sides; ChaCha20-Poly1305 seals then opens a frame with tag verification passing; a tampered ciphertext or replayed nonce is **rejected**. This is the graduation from `[-sim]` — first crypto execution on hardware.
- M1 result logged in `smoke/M1_RESULTS.md` with device identity (not a host run).

## Dependencies
- blocked_by: **p0-mini-boot** — "Boot ARM-Linux from SD on Mini / AD9361 enumerate / GPS+PPS lock" (need a running Cortex-A9 Linux target before any on-device run).

phi^2 + phi^-2 = 3