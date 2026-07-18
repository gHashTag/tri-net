# SHA-256 in t27 + on-chain claim verifier (2026-07-18)

## B (closed): real SHA-256 in the t27 golden pipeline (tri_sha256.t27)

Weak point: the DePIN Merkle commitments used `mix32` -- fast, but NOT a hash a real
blockchain can recompute, so the claims were not on-chain-verifiable. Fix: a real
SHA-256, single 512-bit block, fully unrolled in t27 (no loops/arrays; gen-rust drops
tuples, so one function computes all 8 H words and returns the selected one). Pure u32
add/rotate/xor/shr -- no multiply. Verified BIT-EXACT against the canonical vector:

```
sha256("abc") = ba7816bf 8f01cfea 414140de 5dae2223 b00361a3 96177a9c b410ff61 f20015ad
```

All 8 output words match through the golden pipeline (t27c gen-rust -> rustc --test).
768-line spec, 8 test blocks. Solana computes SHA-256 natively -> the node and an
on-chain program now compute the SAME Merkle root.

## C (closed on-node + reference): SHA-256 on the node ARM + contract verifier

`sha256demo` mode runs the REAL SHA-256 on node .12 ARM:

```
sha256("abc") on node ARM -> CORRECT (0xBA7816BF...0xF20015AD)
sha256-Merkle parent(0x11111111,0x22222222) = 0xBC433BA9 (ref 0xBC433BA9: MATCH)
sha256-Merkle root=0xB55291AE; node0 inclusion proof -> VALID; forged leaf -> REJECTED
```

The chain-verifiable hash runs on the node's own ARM, and a SHA-256 Merkle inclusion
proof verifies (forgery rejected). `docs/onchain/verify_claim.md` gives the reference
contract (Anchor/Rust) that consumes the canonical claim (`relay_meter claim`) and
mints $TRI on a valid SHA-256 inclusion proof -- the algorithm is identical to
`tri_merkle.t27`'s `merkle_verify8`, only the hash is swapped to SHA-256.

## The DePIN stack is now chain-ready end-to-end

signed Proof-of-Relay receipt -> integrity gate + FEC + interleaver -> SNR-weighted
payout -> Merkle round root -> append-only ledger -> Merkle account (balance proof) ->
bond/slashing -> trustless challenge game -> **SHA-256 (chain-verifiable hash)** +
reference on-chain claim verifier. Every layer on t27 + node ARM.

## Honest boundary

- The on-node Merkle demo still uses 32-bit `mix32` nodes for speed; swapping to 256-bit
  SHA-256 nodes (the primitive is ready) is the last integration step.
- No deployed contract; `docs/onchain/verify_claim.md` is a reference skeleton.

## A: OTA still flash-gated (no radio this wave).

Boards left clean: TX LO pd=1 on .11/.12/.13.
