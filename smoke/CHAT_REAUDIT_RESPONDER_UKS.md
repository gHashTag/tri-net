# Multi-Agent Re-Audit — Responder-Side UKS in PQXDH — Results (2026-07-09)

**Component:** `trios-mesh` `src/chat/x3dh.rs`, `src/chat/identity.rs`
**Fix commit:** `b7206d7`
**Method:** 4-agent adversarial re-audit of the three hardest chat-crypto surfaces
(ratchet, x3dh, group), each finder given the prior SOLO conclusions as "claims to
refute." **1 CONFIRMED (HIGH, practical), 0 refuted.** ratchet and group returned
sound (the finder confirmed the stage-and-commit and replay-window designs).

## Why this matters: the independent cross-check earned its keep

The iter25–27 SOLO pass concluded the chat layer was sound (bar the already-fixed
initiator binding). It **missed** this responder-side UKS. A fresh adversarial
agent, told to try to break x3dh beyond the solo conclusion, found it and proved
it with a compiled passing exploit test. Solo review is thorough but
single-perspective; this is exactly the class of subtle crypto bug that an
independent adversarial pass catches.

## The finding (HIGH, practical): responder identity not bound into the root

Chain, all verified against the real source:

1. **Endorsement ≠ ownership.** `PrekeyBundle::verify()` checks every prekey
   signature against the bundle's *own* `ed_vk`. It proves the `ed_vk` holder
   *endorses* the public prekeys — never that it *owns* the corresponding secrets
   (no proof-of-possession). So a malicious member Mallory copies Bob's public
   bundle, sets `ed_vk = mallory.identity()`, and re-signs Bob's **real**
   `ik_pub / spk_pub / kem_ek / OPK` publics under her own Ed25519 key.
   `verify()` passes.
2. **The root ignored `ed_vk`.** `root = HKDF(salt, dh1‖dh2‖dh3‖[dh4]‖kem_ss,
   "root")` — only the X25519 DH publics and the KEM secret, all Bob's real keys.
   `ed_vk` was never mixed in.
3. **Cross-wiring.** Alice runs `initiate()` against the relabelled bundle,
   believing the peer is Mallory. An on-path attacker forwards her `InitialMessage`
   to the *real* Bob; `respond()` re-derives the identical root. Both sides share a
   working key — but Alice's session, which she attributes to **Mallory**, is
   cryptographically **honest Bob's**. (Mallory learns no plaintext — she holds no
   key — but the responder-identity misattribution is deterministic.) This defeats
   the R-CHAT-5 "you know which identity you're talking to" goal. The iter24 fix
   (`cbc0319`) bound only the **initiator** direction.

## Fix (`b7206d7`)

Fold **both** long-term Ed25519 identities into the root's HKDF `info`:

```
root_info = "root" || initiator_id || responder_ed_vk
```

- initiator computes it as `(alice.identity(), bundle.ed_vk)`;
- responder computes it as `(msg.initiator_id, bob.identity())`.

Under the attack Alice mixes `ed_vk = Mallory` while Bob mixes his own real
`ed_vk`, so the two roots differ and the first AEAD fails **closed** (no silent
cross-wiring). Honest sessions are unaffected (both mix the same real `ed_vk`).
Bound via `info`, not a signed transcript, so PQXDH stays **deniable** (R-CHAT-4).
This matches how Signal PQXDH (which the module cites) prevents UKS — by folding
both parties' identity keys into the derived secret.

Regression test `responder_uks_is_closed_by_root_identity_binding` (in
identity.rs, where a verifying-but-relabelled bundle can be constructed): honest
Bob can no longer decrypt Alice's message. All chat tests pass.

Optional follow-up (not done): add proof-of-possession for the SPK/IK in the
bundle to close the endorsement-vs-ownership gap at its source, rather than
compensating for it in the root.

## Note on the shared working tree

The trios-mesh working tree currently carries another actor's in-progress work
(new `src/qos.rs`, uncommitted `src/lib.rs` edits; a `qos` starvation test fails
and `tun.rs` has unused imports). That is unrelated to this crypto change and was
left untouched — only `src/chat/x3dh.rs` + `src/chat/identity.rs` were committed.
