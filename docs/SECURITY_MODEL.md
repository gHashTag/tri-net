# Security model: replay, nonce, forward secrecy for a broadcast mesh

A spec-first security layer for the drone mesh. Four `.t27` specs, each generated to
Rust (host) and Verilog/C/Zig (FPGA) by `t27c`, machine-verified by property tests
over the generated code. It sits ABOVE the AEAD cipher (AES-GCM / ChaCha20-Poly1305)
and BELOW the transport, hardening the per-frame envelope against the attacks a
broadcast radio actually invites. Parallel to FEC_PIPELINE.md and ROUTING_METRIC.md.

## Threat model

A drone mesh transmits in the open. An attacker within radio range can:

1. **Capture and re-inject** a valid, already-authenticated frame (a REPLAY) -- the
   AEAD tag still verifies because it is a genuine frame, so authentication alone
   does not stop it.
2. **Force nonce reuse** if the nonce is chosen carelessly -- and AEAD under a
   repeated (key, nonce) is catastrophic (plaintext-XOR leak + auth-key forgery).
3. **Compromise a current key** and try to read PAST traffic (no forward secrecy).

Out of scope here: the AEAD cipher itself and the initial key exchange / handshake
(these are separate specs). This layer assumes a shared root key exists and each
sender emits a per-sender monotone sequence number.

## The three primitives + the capstone

```
  per-sender monotone seq  -+------------->  replay_window   (accept seq at most once)
                            |
                            +->  aead_nonce   nonce = sender_id<<64 | seq   (never reused)
                            |
                            +->  key_ratchet  MK_n = KDF(CK_n||MSG)         (forward secrecy)
                                                 |
         frame (sender, seq, nonce) ------------+-->  crypto_capstone.accept_frame
                                                          = fresh AND nonce-bound  ->  admit / drop
```

The single monotone sequence per sender ties all three together: it is the replay
window's key, the nonce's low 64 bits, and the ratchet's message index.

## Module map (4 specs)

- `replay_window` -- anti-replay sliding window. State: a `u64` bitmap + `highest`
  accepted sequence (bit b = "highest - b was seen", no byte arrays). `accept`
  (pure: ahead=ok, in-window+unseen=ok, in-window+seen=replay, below=too-old),
  `next_highest` (monotone), `next_bitmap` (slide/set, resets on a gap >= W=64).
- `aead_nonce` -- deterministic 96-bit nonce in a `u128`: `make_nonce(sender, seq)
  = sender<<64 | seq`; `nonce_sender` / `nonce_sequence` / `round_trips` (the
  injectivity witness); `needs_rekey` (before the GCM safe limit 2^31).
- `key_ratchet` -- symmetric key schedule. `chain_next(ck)=kdf(ck^CHAIN)`,
  `message_key(ck)=kdf(ck^MSG)`, `chain_key_at(root,n)` (advance loop),
  `message_key_at`. The `kdf` is an overflow-free xorshift placeholder to exercise
  the structure; a real deployment substitutes a ONE-WAY KDF (HKDF-SHA256 / BLAKE2)
  -- that is what provides the forward secrecy, documented, not claimed of the mix.
- `crypto_capstone` -- the receive decision. `accept_frame(bitmap, highest, sender,
  seq, nonce)` = `replay_window.accept(seq)` AND `nonce == aead_nonce.make_nonce`;
  `frame_key(root, seq)` from the ratchet; `frame_needs_rekey`.

## Machine-verified security invariants

Each is proven as a property over the generated Rust, not asserted:

- **Accept-at-most-once (anti-replay):** over packet streams (in-order + duplicates,
  out-of-order within the window, too-old after a jump), no sequence is accepted
  twice; after accepting 1..50, replaying the whole set is fully rejected.
- **Nonce injectivity (no reuse):** 40,000 nonces (40 senders x 1000 sequences) are
  all distinct, each round-trips to its (sender, seq); boundary (u32::MAX, u64::MAX)
  round-trips in the u128 without overflow. Distinct (sender, seq) => distinct nonce.
- **Ratchet: determinism + domain separation + distinctness:** both endpoints derive
  the same key; the message key never equals the next chain key (MK_n != CK_{n+1});
  5,000 message keys with no reuse; different roots give different key streams.
- **Capstone: replay is defeated end-to-end:** a stream of 30 genuine frames is
  admitted, then re-injecting every one WITH ITS CORRECT nonce is rejected (the
  window remembers the sequence) -- replay defeated even with an authentic nonce; a
  nonce for the wrong sequence or wrong sender is rejected (nonce binding).

## Scientific grounding

- Anti-replay window: IPsec (RFC 2401) / RFC 6479 sliding-window; DTLS 1.3.
- Nonce-misuse catastrophe: AES-GCM / ChaCha20-Poly1305 security proofs require nonce
  uniqueness per key; reuse breaks confidentiality and authenticity (Joux forbidden
  attack). Injectivity = uniqueness.
- Forward secrecy via a one-way KDF chain: Signal symmetric-key ratchet; a one-way
  function is thermodynamically irreversible -- past keys cannot be recomputed from a
  compromised current key.
- Monotone sequence as an arrow of time: a replayed frame tries to move the sequence
  backward, which the window forbids.

## Boundaries

- These specs model STRUCTURE (window, nonce layout, ratchet chain), not the AEAD
  cipher or the KDF hash -- both are substituted with real primitives at deployment,
  the same way the FEC specs model the code, not the modem.
- No key exchange / handshake here (PQXDH-style establishment is a separate concern);
  a shared root key and per-sender sequencing are assumed.
- All logic is generated from the specs; `gen/` is rebuilt by build.rs. Specs and the
  pending t27c codegen fixes live on `codegen-clean`, not yet resealed/merged to
  master (a coupled step; see t27 docs/PARSE_SILENT_DROP_AUDIT.md and MERGE_RUNBOOK.md).

phi^2 + 1/phi^2 = 3 | TRINITY
