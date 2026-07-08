# Solo Security Review: identity, agent, ratchet, store (iter26)

**Date:** 2026-07-08
**Scope:** `src/chat/identity.rs`, `src/chat/agent.rs`, `src/chat/ratchet.rs`, `src/chat/store.rs`
**Method:** Manual code review (subagent workflow unavailable — session limit)

## Result: NO exploitable code-level bugs found

All four files are well-written crypto code at Signal-reference level. Every
`verify()` path is correct: pinned issuer/CA checks, session scope enforcement,
expiry bounds, staged-clone commit-before-mutation. No panics are possible from
malformed network input.

## Properties verified per file

### identity.rs (472 LOC)

- **PrekeyBundle::verify()** — checks all 4 signature types (ik, spk, kem, each
  opk) against `ed_vk`. Rejects wrong-length KEM key. Domain separation via CTX_
  constants prevents cross-field replay. ✓
- **AgentIdentity::verify()** — pinned CA check + signature over
  `(agent_id ‖ scope.encode())`. Scope tampering breaks binding. ✓
- **verify_ik_binding()** — iter24 fix binding initiator identity to DH key. ✓
- **All VerifyingKey::from_bytes** calls handled with let-Ok-else. ✓

### agent.rs (557 LOC)

- **CapabilityToken::verify()** — pinned issuer + session match + expiry +
  signature over full transcript including nonce and issuer bytes. ✓
- **authorize_tool()** — proper AND-chain: manifest.verify ∧ manifest.tool==tool
  ∧ token.verify ∧ token.scope.allows(tool). Message text never consulted. ✓
- **ToolManifest::verify()** — pinned publisher + signature. Encoding is
  unambiguous (tool has u32 length prefix). ✓
- **InjectionClassifier** — transparent pattern gate, explicitly noted as
  stand-in for quarantined LLM. Not a crypto primitive. ✓

### ratchet.rs (571 LOC)

- **Staged clone commit**: forged messages never mutate live ratchet state. ✓
- **MAX_SKIP=256** per-step + **MAX_SKIP_TOTAL=2048** aggregate — skipped-key
  DoS bounded at Signal spec level. ✓
- **Aggregate bound enforced BEFORE caching** (line 373): prevents growth past
  cap. ✓
- **Replay detection**: `until < n_recv` → `RatchetError::Replay`. ✓
- **Header::decode()** returns `Result`, never panics on short/truncated input. ✓

### store.rs (177 LOC)

- **Argon2id** KDF (OWASP params: 19 MiB, t=2, p=1). ✓
- **ChaCha20-Poly1305** AEAD with record-index-as-AAD. ✓
- **Documented limitation**: trailing truncation not self-detecting (commitment
  deferred to deployment layer). ✓
- **get()** handles records shorter than 12-byte nonce → returns None. ✓

## Regression locks added (12 tests, commit `28cce63`)

| File | Test | Property locked |
|------|------|-----------------|
| identity | `bundle_with_all_zero_ed_vk_does_not_panic` | Malformed identity key doesn't crash |
| identity | `bundle_with_empty_one_time_still_verifies` | Zero OPKs is valid |
| identity | `agent_identity_with_random_bytes_does_not_panic` | Random bytes in all fields → reject, no panic |
| agent | `token_with_expiry_zero_is_always_expired` | expiry=0 fails at any now≥0 |
| agent | `empty_scope_never_authorizes` | Empty scope grants nothing |
| agent | `token_with_random_sig_bytes_does_not_panic` | Random issuer+sig → reject |
| agent | `manifest_with_random_bytes_does_not_panic` | Random publisher+sig → reject |
| ratchet | `empty_wire_is_short_header_not_panic` | Zero-length input → ShortHeader |
| ratchet | `truncated_header_is_short_header_not_panic` | 10 bytes → ShortHeader |
| ratchet | `header_claims_kem_ct_but_body_truncated` | Claims kem_ct but too short → ShortHeader |
| store | `get_on_empty_store_returns_none` | Empty store → None |
| store | `get_with_corrupted_short_record_returns_none` | 3-byte record → None |

## Chat-crypto audit status (cumulative)

| Surface | Reviewer | Finding count | Status |
|---------|----------|--------------|--------|
| x3dh.rs | iter24 (solo) | 1 (identity binding) | Fixed `cbc0319` |
| group.rs | iter25 (solo) | 0 (correct in trust model) | Panic-locks `26657e8` |
| sealed.rs | iter25 (solo) | 0 (correct in trust model) | Panic-locks `26657e8` |
| identity.rs | iter26 (solo) | 0 | Panic-locks `28cce63` |
| agent.rs | iter26 (solo) | 0 | Panic-locks `28cce63` |
| ratchet.rs | iter26 (solo) | 0 | Panic-locks `28cce63` |
| store.rs | iter26 (solo) | 0 | Panic-locks `28cce63` |

**Full chat-crypto surface reviewed.** 1 finding fixed (iter24 PQXDH identity
binding), 0 remaining exploitable bugs. All network-input paths now have
panic-safety regression locks.

## Deferred items (design-level, not code bugs)

1. **0xE2 handshake auth** (iter23 #5): forged handshake desyncs working session.
   Fix = MAC(KDF(ss),...) on handshake; requires 2-board RF validation.
2. **Reply target from wire `sender`** (iter23 #3): multi-hop file-reply uses
   wire field, not authenticated source. Fix = end-to-end identity (design decision).
3. **MLS roster-change auth** (iter25): `install_epoch` trusts caller; group
   authority not authenticated at this layer. Fix = daemon-level signing.

phi^2 + phi^-2 = 3
