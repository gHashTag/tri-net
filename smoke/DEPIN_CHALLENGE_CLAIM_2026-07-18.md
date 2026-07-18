# Challenge game + canonical on-chain claim (2026-07-18)

## C (closed): decentralized challenge game (tri_challenge.t27)

Weak point: catching a lying node relied on a TRUSTED settlement re-metering the
stream -- a single point of trust. Fix: any node (challenger) disputes another's
(defender's) receipt by posting a bond; ANYONE re-meters the same relayed stream to get
the truth seal; the party whose seal disagrees with the truth loses and forfeits its
bond to the winner. No trusted arbiter needed.

`is_valid_challenge`, `resolve`, `defender_bond_after`, `challenger_bond_after`. 6
invariants (dispute needs disagreement, honest defender wins, lying defender slashed,
bond conservation + direction, griefing unprofitable). `challenge` mode on node .12 ARM:

```
lying defender: defender_seal=0xBADBAD00 truth=0x6EAC3F90
  -> DEFENDER LIED -> defender slashed 100->0, challenger rewarded 100->200
honest defender: defender_seal==truth
  -> DEFENDER HONEST -> challenger slashed 100->0, defender 100->200
```

Catching a liar is profitable; challenging an honest node costs the challenger its
bond. So honest receipts survive and false ones are caught -- trustlessly.

## B (on-chain interface, hash-upgrade pending): canonical claim (claim mode)

The exact record a smart contract consumes to mint $TRI: `state_root` (stored on-chain),
`(node_id, balance, idx)`, and the Merkle `proof` (3 sibling hashes). The contract
recomputes the account state root by folding the proof and accepts iff it matches.
`claim` mode on node .12 ARM:

```
state_root = 0x7268C646   (stored on-chain)
node_id=0 balance=2108 idx=0
proof = [0x6FB509F2, 0x2610EA88, 0xFCD643F6]
contract verify -> ACCEPT (mints 2108 $TRI to node0)
```

This defines the on-chain claim interface. HONEST BOUNDARY: the hash is mix32; a real
Solana/EVM contract needs sha256/keccak -- implementing sha256 in t27 (all u32
add/rotate/xor, no multiply -- 64 rounds unrolled) is the dedicated next step.

## A: OTA still flash-gated

No radio transmitted this wave. Prior waves exhausted the non-destructive diagnosis
(config-read: all 30.72 MHz, FIR off; dmesg: no DMA underrun -> silent timing issue).
Closing needs the PL DSSS PHY (destructive flash + user presence). Deferred.

## t27c lesson

gen-rust SILENTLY DROPS tuple-returning functions (typecheck passes, but the function
is absent from the generated Rust). `settle_bonds(...) -> (u32,u32)` was skipped; split
into two scalar functions. Verify by counting `pub fn` in gen output vs the spec.

Boards left clean: TX LO pd=1 on .11/.12/.13.
