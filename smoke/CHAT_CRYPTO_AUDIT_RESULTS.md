# Chat-Crypto Audit — Results (2026-07-08, PARTIAL)

**Component:** `trios-mesh` `src/chat/*` (PQXDH, triple ratchet, MLS groups, sealed
sender, capability tokens, at-rest store, anti-metadata padding — 3043 LOC)
**Fix commit:** `cbc0319`
**Method:** 6-surface adversarial workflow (finder per surface → independent
verification). **INCOMPLETE:** 5 of 8 agents aborted on a session usage limit
(resets 23:10 Asia/Bangkok) — the finders for **ratchet, group, identity** never
ran, and two **pqxdh** verifiers aborted. So the "0 confirmed" the harness
returned is NOT a clean-audit result; it reflects an aborted run.

## What completed

- **sealed** and **hygiene** finders ran and returned no findings (not
  independently re-verified here — treat as provisional).
- The **pqxdh** finder ran and produced two candidates; its verifiers aborted, so
  **I verified both by hand** against the real code.

## pqxdh finding — CONFIRMED and FIXED (`cbc0319`)

**Initiator identity not bound to its DH key (authenticity).** The PQXDH
`InitialMessage` (`x3dh.rs`) carries the initiator's stable Ed25519 `initiator_id`
AND its X25519 `initiator_ik`, but `respond()` authenticated only by possession
of `initiator_ik` and never bound `initiator_id` to it. The responder's prekey
bundle already signs its own ik (`CTX_IK`), but the initiator's ik was unsigned on
the wire — an asymmetry. A peer could present its own `initiator_ik` while
claiming another node's `initiator_id` (impersonation / unknown-key-share) the
moment any consumer trusts `initiator_id` to name the sender.

*Severity, honestly:* the finder rated it HIGH assuming a consumer names the
sender by `initiator_id`. Verified fact: `initiator_id` is currently read nowhere
in the crate (grep-confirmed), so there is no *current* impersonation — it is a
**latent** authenticity gap. But the field exists precisely to name the sender, so
the fix closes it before first use.

**Fix** (mirrors the codebase's own `CTX_IK` signing pattern): `InitialMessage`
now carries `ik_sig` = the initiator's Ed25519 signature over its `initiator_ik`;
`respond()` verifies it **first, before consuming any one-time prekey**. The
signature is over the static key (not the transcript), so PQXDH stays deniable.

**Related (one-time-prekey exhaustion, replay-resistance).** `respond()` consumed
the referenced OPK before authenticating, and ML-KEM implicit rejection makes any
correct-length `kem_ct` "succeed" — so unsigned junk could burn Bob's OPK pool
anonymously, forcing sessions onto the replayable no-OPK path (the standard X3DH
caveat, which a misleading code comment denied). The identity check now precedes
OPK consumption, so exhaustion requires a valid, attributable identity; the
comment is corrected to state the no-OPK caveat honestly.

Tests: `forged_initiator_identity_is_rejected`,
`unsigned_message_cannot_burn_a_one_time_prekey`. **233 tests pass.**

## Pre-analysis (RTFM, done by hand before the audit)

`ratchet.rs` already bounds the classic Double-Ratchet skipped-message-key DoS
(the exact issue the Signal spec warns about): `MAX_SKIP = 256` per step,
`MAX_SKIP_TOTAL = 2048` aggregate, plus a replay check (`until < n_recv`). This
surface is carefully written — a reason to expect few findings there, but it was
NOT reached by the aborted finder, so it still needs a clean pass.

## Outstanding

Re-run the audit after the session limit resets (23:10 Asia/Bangkok) to cover the
surfaces whose finders aborted: **ratchet, group, identity**, plus a re-verify of
the provisional **sealed / hygiene** "no findings." This is the honest next step —
the crypto layer is NOT yet cleared.
