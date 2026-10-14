# RFC: fix the mesh crypto handshake (N3-N5) — for review before implementation

Status: PROPOSAL. Not implemented. Crypto stays hand-written Rust (t27 cannot
express it — see #62); this design is for the human-written `src/crypto.rs` /
`src/bin/trios_meshd.rs` and needs sign-off on the approach before coding.
Anchor: phi^2 + phi^-2 = 3.

## The three defects (from the wave audit, verified in code)

- **N3 — handshake is not authenticated.** `NoiseXX::complete_initiator`
  (`crypto.rs:132`) and `complete_responder` (`:151`) compute only `ee` and
  `ss`, then call `combine_dh_shares(&ee, &ss, &ss)` — passing `ss` in BOTH the
  `es` and `se` slots. The real `es`/`se` Diffie-Hellman operations are never
  performed, and no transcript hash binds ephemeral<->static keys. The
  `AllowList` (`:183`) exists but is never consulted inside `complete_*`. The
  test `noise_xx_resistant_to_mitm` (`:738`) even asserts the MITM party
  DECRYPTS the victim's traffic — encoding the break as expected behaviour.
- **N4 — HELLO metric auth is dead + keyed by a constant.** `HELLO_MAC_KEY`
  (`trios_meshd.rs:13`) is a source-embedded constant; `verify_mac`/`is_fresh`
  are never called in the daemon RX path, so a neighbour can forge the `heard`
  list and game ETX.
- **N5 — static keys are public.** `seed_for(id) = Sha256("trios-mesh/demo/v1/
  node/" || id)` (`trios_meshd.rs:37`) derives each node's static secret from
  its public NodeId, so any reader of the open-source daemon recomputes every
  node's private key.

## Proposed design

### 1. Correct the handshake (Noise-IK-style over the existing primitives)
Keep X25519 + ChaCha20-Poly1305 + the existing `Session`/`ratchet` transport.
Change only key agreement + peer authentication:

- In `complete_initiator`, compute THREE distinct shares:
  `ee = e_i . e_r`, `es = e_i . s_r`, `se = s_i . e_r`; mirror in
  `complete_responder` (`es = s_i . e_r`, `se = e_i . s_r` by role). Feed the
  real `(ee, es, se)` into `combine_dh_shares` (its signature already expects
  three distinct inputs — only the call sites are wrong).
- Mix a running transcript hash `h = H(h || each public key/DH output)` into the
  KDF so the session key binds both parties' ephemeral AND static keys.
- Make `complete_*` take `&AllowList` (or the expected peer NodeId->PublicKey)
  and REJECT if `peer_static` is not the allow-listed key for the claimed
  identity, returning `Result<Session, MeshError::Auth>` instead of an
  always-succeeding `Session`.
- Rewrite `noise_xx_resistant_to_mitm` to assert the MITM party FAILS to open
  the victim's frames (the current assertion is inverted).

### 2. Wire HELLO authentication (N4)
- Derive the per-link HELLO MAC key from the established session key
  (e.g. `HKDF(session_key, "hello-mac")`), not a global constant. Remove
  `HELLO_MAC_KEY`.
- In the daemon RX path, before `observe()` feeds a neighbour's `heard` list
  into ETX, call `verify_mac` + `is_fresh` and track last-seen seq for replay;
  drop on failure. Use a constant-time comparison (`subtle::ConstantTimeEq`).

### 3. Provision real static keys (N5)
- Load each node's static secret from an out-of-band keystore file (env-pointed,
  not world-readable), never `from_seed(NodeId)`. Keep `from_seed` only behind a
  `--demo` flag for local loopback.
- Populate the `AllowList` (NodeId -> PublicKey) from the same provisioning, and
  gate session establishment on it (step 1).

## Test plan (must all pass)
- MITM: an attacker substituting its own static key cannot open either party's
  frames (rewritten `noise_xx_resistant_to_mitm`).
- Allow-list: a peer whose static key is not allow-listed gets `MeshError::Auth`.
- HELLO forge: a neighbour forging another node's `heard` list is rejected
  (bad MAC) and does not move ETX.
- Replay: a re-sent HELLO is rejected by `is_fresh`/seq tracking.
- Regression: the existing 103 tests stay green; add the four above.

## Formal check (optional, Lane B)
Model the revised handshake in Tamarin (AutoTam, arXiv:2606.19937) to prove
mutual authentication + forward secrecy, rather than asserting it.

## Decision needed from the owner
1. Noise-IK vs a full Noise-XX (three-message) — IK is one-round-trip and fits
   a known-peer mesh; confirm.
2. Keystore format / provisioning mechanism for static keys (file? per-node
   config? an existing provisioning path?).
3. Whether to gate this behind a feature flag during rollout.
