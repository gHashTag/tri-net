# Chat-Crypto Solo Review — group.rs + sealed.rs — Results (2026-07-08)

**Component:** `trios-mesh` `src/chat/group.rs` (partial-MLS group, 427 LOC),
`src/chat/sealed.rs` (sealed sender, 157 LOC)
**Commit:** `26657e8`
**Method:** manual by-hand review (the iter24 audit workflow could not reach these
surfaces — its finders aborted on a session usage limit; subagents remain
unavailable, so this pass is solo, no workflow).

## Verdict: sound within the documented trust model — no exploitable code bug

Both files are carefully written. I traced the high-value bug classes for each
and found no fixable defect; the residual weaknesses are **design-level
assumptions that the modules explicitly document**, not code bugs.

### group.rs (sender-key partial-MLS)

Checked and OK:
- **Nonce uniqueness:** the AEAD nonce is `nonce_of(counter)` and the key is the
  per-`(sender, epoch)` sender key (`HKDF(epoch_secret; group_id‖member‖epoch)`).
  Distinct senders → distinct keys; the per-sender monotonic counter makes the
  nonce unique under a fixed key. No two-time-pad in the intended one-writer-per-
  sender usage.
- **Replay window:** the 64-wide sliding window (`Window::check_and_set`) is
  correct — the highest counter is marked seen, out-of-window is rejected, and it
  resets per epoch (safe because the key changes).
- **Epoch/roster integrity of the wire:** epoch, sender, and counter are bound as
  AEAD associated data, so a tampered header fails to open.
- **Removed-member exclusion (G-C5):** `rekey_for_remove` bumps the epoch and
  rerolls the secret; the removed member never receives it and cannot derive the
  new sender keys (tested).
- **install_epoch replay:** an equal/older-epoch re-install is rejected
  (`epoch_secret_installed` guard), so a stale install can't overwrite the secret.
- **Sorted-roster invariant:** `members` stays sorted through create/add/remove/
  install, so the `binary_search` membership check is valid.

Documented design caveats (NOT defects — explicit in the module docs):
- **Unauthenticated roster changes:** `install_epoch` "trusts its caller for
  authenticity." Nothing in this layer proves an epoch/roster update came from a
  legitimate group authority; a future daemon wiring must authenticate the sealed
  1:1 message that carries it (e.g. bind it to an admin identity / signed commit).
- **Group-level authenticity:** any member can compute any member's sender key, so
  a member can send *as* another member. This is the intended deniability property
  (R-CHAT-4), not a bug — but it means intra-group sender authenticity is not
  cryptographic.

### sealed.rs (sealed sender)

Checked and OK:
- **Panic-safety:** `open_sealed` takes attacker bytes; `PublicKey::from([u8;32])`
  never panics, and decryption returns a `Result` mapped to `None`. `decode`
  length-checks. No panic / OOB on any input.
- **Fixed nonce is safe:** the key is `HKDF(DH(eph, recipient); eph_pub‖route)`
  with a fresh ephemeral per message, so `(key, nonce=0)` is unique per message.
- **Route binding:** the route is both HKDF info and AEAD AAD, so a swapped route
  fails to open (tested).
- **Unlinkability (G-C3):** the wire carries only a fresh ephemeral + ciphertext;
  no sender field.

Theoretical note (not fixed): X25519 `diffie_hellman` does not reject low-order
points, so a crafted `eph_pub` yields a known all-zero shared secret. This lets a
non-recipient craft an envelope the recipient can open, but the sealed layer is
not the authenticator — authorship lives in the authenticated `inner` (sender
cert + ratchet ciphertext), which such an envelope cannot forge. Standard X25519
contributory-behavior caveat; out of scope for a fix here.

## Concrete deliverable

Regression tests locking the verified panic-safety of the two network-input entry
points: `sealed::malformed_envelope_never_panics_and_opens_to_none`,
`group::malformed_frame_is_rejected_not_panicked`. 235 tests pass.

## Outstanding (still needs the workflow after the limit resets)

`ratchet.rs` (pre-analysis: already bounds skipped-key DoS — `MAX_SKIP=256`,
`MAX_SKIP_TOTAL=2048`, replay check) and `identity.rs`/`agent.rs` `verify()` paths
were not covered by this solo pass. Re-run the adversarial workflow after 23:10
Asia/Bangkok for independent multi-agent coverage of those.
