# M1 Crypto Smoke — Hardware Results

**Date:** 2026-07-07
**Hardware:** 3× P201Mini (Zynq 7020 Cortex-A9, armv7l)
**Binary:** smoke-m1 (Rust, cross-compiled armv7-unknown-linux-musleabihf, static)

## Results: 3/3 BOARDS PASS

### Board 1 (192.168.1.11)
```
[M1] X25519 handshake complete: node 1 <-> node 2           ✅
[M1] AEAD round-trip OK: 44→83 bytes ChaCha20-Poly1305      ✅
[M1] tamper rejected: flipped tag → Auth error              ✅
[M1] replay rejected: re-delivered frame → Replay error     ✅
[M1] PASS
```

### Board 2 (192.168.1.12)
```
[M1] PASS — identical results
```

### Board 3 (192.168.1.13)
```
[M1] PASS — identical results
```

## Milestone Status

| Milestone | Status |
|-----------|--------|
| M1 crypto (X25519 + ChaCha20-Poly1305 + ratchet + zeroize) | ✅ hw-tested |
| AD9361 detection | ✅ all 3 boards |
| Mesh connectivity (board-to-board ping) | ✅ all pairs |
| OTA RF signal detection (RSSI +8.75 dB) | ✅ Board 1→3 |
| M2 two-board mesh | ⏳ next |
| M2 three-board convergence | ⏳ next |

φ² + φ⁻² = 3
