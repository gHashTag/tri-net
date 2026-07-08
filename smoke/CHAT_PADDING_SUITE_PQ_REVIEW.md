# Chat-Crypto Solo Review — padding / suite / pq (final chat surfaces) — 2026-07-08

**Component:** `trios-mesh` `src/chat/padding.rs`, `src/chat/suite.rs`,
`src/chat/pq.rs`
**Commit:** `bd2790b`
**Method:** manual by-hand review (subagent workflows still unavailable under the
session limit). Completes a solo pass over **all 11 chat modules**.

## Verdict: sound within the documented models — no exploitable bug

### padding.rs (anti-metadata: buckets, queue rotation, cover traffic)
- **`unpad` is panic-safe:** `len < 4` guarded; the length check is written as
  `len > padded.len() - 4` (not `4 + len`, which the authors' comment notes would
  overflow on 32-bit) so a corrupt length prefix fails closed. No OOB.
- **No padding oracle:** `unpad` runs on already-decrypted (AEAD-authenticated)
  plaintext — an attacker cannot feed chosen bytes to it, so there is no oracle.
- **Fisher-Yates flush** uses the OS CSPRNG; the only nit is `next_u32 % (i+1)`
  modulo bias, negligible for realistic queue sizes and irrelevant to the G-C9
  t-test.
- Added regression test `unpad_rejects_inconsistent_length_prefix_without_panic`.

### suite.rs (ciphersuite versioning / PQ migration)
- **`from_wire`** is exhaustive, returns `None` on an unknown value — no panic.
- **`negotiate`** picks the highest mutually-supported suite by wire value, so a
  PQ suite wins over classical when both are offered.
- **Caveat (documented, not a bug):** `negotiate` is a pure function.
  Downgrade-resistance requires the offered suite lists to be **authenticated in
  the handshake transcript** — and the suite id is **not yet bound into the x3dh
  transcript**. When suite negotiation is wired to the handshake, the negotiated
  suite + offered lists must be mixed into the session root (or confirmed in an
  authenticated finished-message), or an active attacker can strip the hybrid
  suite and force a classical downgrade. Latent until wired.

### pq.rs (ML-KEM-768 byte helpers)
- **Panic-safe parsing:** `ek_from_slice` / `dk_from_slice` / `decapsulate` all use
  `try_from(..).ok()?` → `None` on a wrong length before any `expect`.
- **Implicit rejection** (FIPS 203 §6.3) is correctly documented: a correct-length
  but garbage ciphertext yields a pseudo-random secret (this is the property the
  iter24 x3dh fix hardened against for OPK exhaustion).
- **Fix:** the module doc claimed the wire sizes were "asserted at compile time,"
  but no such assertion existed. Added
  `const _: () = assert!(size_of::<Encoded<..>>() == KEM_*_LEN)` for EK/DK/CT, so an
  `ml_kem` bump that changed a size fails the build instead of panicking at
  runtime. (Compiles → the sizes match today: 1184 / 2400 / 1088.)

## Whole-layer summary (iter24–iter27 solo pass)

| module | result |
|--------|--------|
| x3dh | **real bug fixed** — initiator identity-binding (`cbc0319`, iter24) |
| group, sealed | sound; panic-locks added (iter25) |
| identity, agent, ratchet, store | sound; panic-locks added (iter26) |
| padding, suite, pq | sound; pq compile-guard + unpad lock (this pass) |
| mod | re-exports only |

The **only real defect** in the entire chat crypto layer was the x3dh
identity-binding (fixed). Everything else is sound within its documented trust
model. Recurring *design caveats* to resolve when the layer is wired to the
daemon (all explicitly documented, none a code bug):
1. group `install_epoch` — roster changes not authenticated in-layer;
2. suite `negotiate` — downgrade needs the negotiation bound into the transcript;
3. group authenticity is group-level (deniable; members can send as each other).

**Stronger check still owed:** a multi-agent adversarial re-run of the audit once
the session usage limit resets — solo review is thorough but single-perspective.
