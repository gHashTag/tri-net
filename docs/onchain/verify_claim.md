# Reference on-chain claim verifier ($TRI mint)

This is the CONTRACT side of the DePIN claim. The node produces a canonical claim
(`relay_meter claim`): the published `state_root`, its `(node_id, balance, idx)`, and a
Merkle inclusion `proof` (sibling hashes). A smart contract stores only the latest
`state_root` per settlement round and mints `$TRI` when a node proves inclusion. The
hash is **SHA-256** — implemented and verified in `specs/tri_sha256.t27` (bit-exact vs
`sha256("abc")`), and Solana exposes it natively (`solana_program::hash::hashv`), so the
contract and the node compute the SAME root.

## Solana (Anchor / Rust) reference

```rust
use anchor_lang::prelude::*;
use anchor_lang::solana_program::hash::hashv; // SHA-256

// A node's account leaf: sha256(node_id_be || balance_be). Matches account_leaf.
fn account_leaf(node_id: u32, balance: u32) -> [u8; 32] {
    hashv(&[&node_id.to_be_bytes(), &balance.to_be_bytes()]).to_bytes()
}
fn hpair(l: &[u8; 32], r: &[u8; 32]) -> [u8; 32] {
    hashv(&[l, r]).to_bytes()
}

/// Fold the proof from the leaf up to the root; `idx` bits pick left/right.
fn fold_proof(mut node: [u8; 32], proof: &[[u8; 32]], mut idx: u32) -> [u8; 32] {
    for sib in proof {
        node = if idx & 1 == 1 { hpair(sib, &node) } else { hpair(&node, sib) };
        idx >>= 1;
    }
    node
}

#[derive(Accounts)]
pub struct Claim<'info> {
    #[account(mut)] pub round: Account<'info, Round>,   // stores state_root
    #[account(mut)] pub node_balance: Account<'info, Balance>,
    #[account(mut)] pub payer: Signer<'info>,
}

pub fn claim(ctx: Context<Claim>, node_id: u32, balance: u32, idx: u32,
             proof: Vec<[u8; 32]>) -> Result<()> {
    let round = &ctx.accounts.round;
    let leaf = account_leaf(node_id, balance);
    let computed = fold_proof(leaf, &proof, idx);
    require!(computed == round.state_root, ClaimError::BadProof);   // inclusion check
    require!(!ctx.accounts.node_balance.claimed_round(round.epoch), ClaimError::DoubleClaim);
    // mint `balance` $TRI to node_id, mark the round claimed
    mint_tri(node_id, balance)?;
    ctx.accounts.node_balance.mark_claimed(round.epoch);
    Ok(())
}
```

## What the node already proves off-chain (matches this contract, bit-for-bit)

`relay_meter claim` prints exactly `state_root`, `(node_id, balance, idx)`, and the
`proof` siblings; `relay_meter sha256demo` runs the same SHA-256 on the node ARM
(`sha256("abc")` bit-exact, and `sha256-Merkle parent` matching a reference). The only
change from the current on-node demo (which uses the fast `mix32` for the 32-bit tree)
is swapping the hash to SHA-256 and widening leaves/roots to 256 bits — the algorithm
(`account_leaf`, `hpair`, `fold_proof`) is identical to `tri_merkle.t27`'s
`merkle_verify8`.

## Remaining work

- Widen the on-node Merkle from 32-bit `mix32` nodes to 256-bit SHA-256 nodes (the
  `tri_sha256.t27` primitive is ready; the tree logic is unchanged).
- Round-root anchoring (`tri_ledger` state chain) as the contract's per-round update.
- Double-claim / replay guard (sketched above via `claimed_round`).
- Signature: bind the claim to the node's Ed25519 key (already produced by
  `relay_meter sign`).
```
EVM note: use `keccak256` instead of `hashv` (EVM-native); the structure is identical.
```
