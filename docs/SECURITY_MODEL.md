# Security model: from key agreement to a hardened frame on a broadcast mesh

A spec-first security layer for the drone mesh. Six `.t27` specs, each generated to
Rust (host) and Verilog/C/Zig (FPGA) by `t27c`, machine-verified by property tests
over the generated code. It spans the whole channel lifecycle -- establishing a
shared key over the open air, confirming it, then hardening every AEAD frame -- and
sits ABOVE the cipher (AES-GCM / ChaCha20-Poly1305) and BELOW the transport.
Parallel to FEC_PIPELINE.md and ROUTING_METRIC.md.

## Threat model

A drone mesh transmits in the open. An attacker within radio range can:

1. **Man-in-the-middle the key exchange** -- run two separate exchanges so each side
   thinks it shares a key with the other (unknown-key-share). Covered by `session`
   key confirmation.
2. **Compromise a current key** and try to read PAST traffic. Covered by `key_ratchet`
   forward secrecy (a one-way KDF chain).
3. **Force nonce reuse** if the nonce is chosen carelessly -- catastrophic for AEAD
   (plaintext-XOR leak + auth-key forgery). Covered by `aead_nonce` injectivity.
4. **Capture and re-inject** a valid, already-authenticated frame (a REPLAY) -- the
   AEAD tag still verifies. Covered by `replay_window`.

Out of scope: the AEAD cipher itself, and post-quantum / long-term-identity
authentication (this layer proves KEY AGREEMENT and confirmation, not identity
binding to a long-term certificate -- a PQXDH-style identity layer is separate).

## The lifecycle: handshake to secure frame

```
   handshake   G^a, G^b  ->  shared = G^(ab) mod P     (Diffie-Hellman agreement)
       |
   session     establish -> root ; confirm_tag ; mutually_confirmed  (MITM defence)
       |                          |
       |                     first_key
       v
   key_ratchet   CK_{n+1}=KDF(CK_n||CHAIN) ; MK_n=KDF(CK_n||MSG)   (forward secrecy)
       |
   per-sender monotone seq  -+-> aead_nonce   nonce = sender<<64 | seq   (never reused)
                             +-> replay_window accept seq at most once
                                        |
   frame (sender, seq, nonce) ----------+-> crypto_capstone.accept_frame
                                             = fresh AND nonce-bound -> admit / drop
```

The single monotone sequence per sender ties the frame layer together: it is the
replay window's key, the nonce's low 64 bits, and the ratchet's message index.

## Module map (6 specs)

- `handshake` -- Diffie-Hellman key agreement in a small prime field (P = 2^31-1 M31,
  products stay < 2^62, no u64 overflow). `mod_pow` (square-and-multiply),
  `public_key`=G^priv, `shared_secret`=peer_pub^priv=G^(ab), `session_root` (binds
  the shared secret to the transcript, symmetric so both roles agree; feeds ratchet).
- `session` -- establishment + KEY CONFIRMATION. `establish`, `confirm_tag`
  (root-keyed MAC over the transcript, domain-separated), `mutually_confirmed` (accept
  only if the peer's tag matches my root -> defeats unknown-key-share), `first_key`.
- `key_ratchet` -- symmetric key schedule for forward secrecy. `chain_next`,
  `message_key`, `chain_key_at`, `message_key_at`. `kdf` is an overflow-free xorshift
  placeholder; a real deployment substitutes a ONE-WAY KDF (HKDF-SHA256 / BLAKE2) --
  that is what provides forward secrecy, documented, not claimed of the mix.
- `aead_nonce` -- deterministic 96-bit nonce in a `u128`: `make_nonce(sender, seq)
  = sender<<64 | seq`; `nonce_sender` / `nonce_sequence` / `round_trips`; `needs_rekey`.
- `replay_window` -- anti-replay sliding window: `u64` bitmap + `highest`. `accept`
  (pure), `next_highest`, `next_bitmap` (slide/set, resets on a gap >= W=64).
- `crypto_capstone` -- the receive decision. `accept_frame` = `replay_window.accept`
  AND `nonce == aead_nonce.make_nonce`; `frame_key` from the ratchet; `frame_needs_rekey`.

## Machine-verified security invariants

Each is proven as a property over the generated Rust, not asserted:

- **Key agreement (handshake):** over 1000 random key pairs, both endpoints reach the
  same shared secret G^(ab) mod P from asymmetric views; `mod_pow` matches an
  independent reference over 500 inputs.
- **Key confirmation + MITM (session):** over 300 random key triples, two honest
  parties reach the same root, confirm each other both ways, and derive the same first
  message key; an attacker's separate exchange yields a different root whose tag is
  REJECTED -- unknown-key-share defeated.
- **Forward secrecy structure (ratchet):** determinism, domain separation
  (MK_n != CK_{n+1}), and 5000 message keys with no reuse; different roots -> different
  streams.
- **Nonce injectivity (no reuse):** 40,000 nonces (40 senders x 1000 sequences) all
  distinct, each round-trips; distinct (sender, seq) => distinct nonce.
- **Accept-at-most-once (anti-replay):** no sequence accepted twice across streams;
  after accepting 1..50, replaying the whole set is fully rejected.
- **Replay defeated end-to-end (capstone):** 30 genuine frames admitted, then
  re-injecting every one WITH ITS CORRECT nonce is rejected -- replay defeated even
  with an authentic nonce; a wrong-sequence or wrong-sender nonce is rejected.

## Scientific grounding

- Diffie-Hellman agreement: G^(ab) = G^(ba) is the commutativity of exponentiation in
  a cyclic group; hardness rests on the discrete-log problem (toy field here, X25519 /
  a PQ KEM at deployment).
- Key confirmation against unknown-key-share: Noise `XX` / Signal handshakes; a MAC
  over the transcript keyed by the derived secret.
- Nonce-misuse catastrophe: AES-GCM / ChaCha20-Poly1305 proofs require nonce
  uniqueness per key (Joux forbidden attack). Injectivity = uniqueness.
- Forward secrecy via a one-way KDF chain: Signal symmetric-key ratchet; a one-way
  function is thermodynamically irreversible.
- Anti-replay window: IPsec (RFC 2401) / RFC 6479; DTLS 1.3. A monotone sequence is an
  arrow of time -- a replay tries to move it backward, which the window forbids.

## Boundaries

- These specs model STRUCTURE (the DH exchange, nonce layout, ratchet chain, window),
  not the underlying number-theoretic / hash primitives -- X25519, HKDF, AEAD are
  substituted at deployment, the same way the FEC specs model the code, not the modem.
  The proven properties (agreement, confirmation, injectivity, no-reuse) are real.
- Long-term identity authentication (binding a public key to a device certificate) is
  a separate PQXDH-style layer.
- All logic is generated from the specs; `gen/` is rebuilt by build.rs. Specs and the
  pending t27c codegen fixes live on `codegen-clean`, not yet resealed/merged to master
  (a coupled step; see t27 docs/PARSE_SILENT_DROP_AUDIT.md and MERGE_RUNBOOK.md).

phi^2 + 1/phi^2 = 3 | TRINITY
