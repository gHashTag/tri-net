# Initiator Anonymity — Anonymous Mesh Frames (iter30)

**Date:** 2026-07-08
**Commit:** `08feb5e` (trios-mesh)
**Tests:** 279 total (+6 anonymity)

## What

New `FrameKind::AnonData` hides the sender's identity from anyone watching the
RF channel. This closes the privacy gap vs Reticulum (which carries no source
address on any packet).

## Design

```
Regular Data frame (backward compat):
  Wire: [ver][Data][src:4][dst:4][ttl]   <- src visible to eavesdropper
  Body: [encrypted payload]

Anonymous AnonData frame:
  Wire: [ver][AnonData][0000][dst:4][ttl]  <- src = 0, no attribution
  Body: [encrypted: [original_src:4][payload]]
```

**What an eavesdropper sees:**
- Kind = AnonData (they know the sender chose anonymity)
- dst (needed for routing — visible)
- ttl (needed for loop prevention — visible)
- src = 0 (no sender identity)
- Ciphertext (opaque without the session key)

**What the final recipient sees:**
- Everything above, plus
- original_src (decrypted from payload prefix)

**What relay nodes see:**
- Only the hop-by-hop neighbor identity (from which session decrypts)
- The original_src inside the encrypted payload passes through unchanged
- Relays forward transparently — no protocol changes needed

## Properties Verified

| Test | Property |
|------|----------|
| `anon_frame_delivers_correct_payload_and_sender` | Decryption yields correct (sender, payload) |
| `anon_wire_header_has_zero_src` | Header src=0, kind=AnonData |
| `anon_and_regular_frames_coexist` | Both modes work simultaneously |
| `anon_frame_tampered_src_byte_fails_auth` | AEAD binds the zero-src header |
| `anon_multiple_packets_preserve_sender` | 5 sequential packets all identify correctly |
| `anon_data_kind_roundtrips` | Wire parse/serialize for AnonData kind |

## Competitive Position

| Feature | Reticulum | Tri-Net |
|---------|-----------|---------|
| Source on wire | Never | Optional (AnonData mode) |
| Backward compat | N/A (always anon) | Yes (Data + AnonData coexist) |
| Routing | Path-based | ETX next-hop |
| Crypto | AES-256-CBC | ChaCha20-Poly1305 + PQXDH |
| FPGA | No | Yes |

phi^2 + phi^-2 = 3
