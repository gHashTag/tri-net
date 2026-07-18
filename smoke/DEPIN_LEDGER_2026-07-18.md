# Persistent $TRI ledger across rounds (2026-07-18)

## Weak point

Per-round settlement (tri_settle) + its Merkle round-root (tri_merkle) are STATELESS:
each round is computed independently, with no lasting, tamper-evident record of
accumulated $TRI balances. The token has no ledger.

## Fix: append-only state-root chain + balance accumulation (tri_ledger.t27)

- `balance_add(bal, reward)` -- a node's balance accumulates across rounds, saturating.
- `state_step(prev_state, round_root, epoch)` -- fold each round's Merkle root into an
  evolving ledger STATE ROOT (like a blockchain's state chain). Order-sensitive and
  dependent on the prior state => append-only + tamper-evident.
- `verify_chain3(...)` -- recompute the ledger state from genesis and the round roots
  and check it against a claimed final root.

6 invariants (balance accumulates + saturates, state deterministic, tamper-evident,
order-sensitive, wrong root rejected). Golden pipeline (t27c gen-rust -> rustc --test).

## Proven on node .12 ARM (`ledger` mode, 3 rounds)

Round 0 uses the ACTUAL Merkle round root 0x12CE67F1 from the prior wave, chaining the
two layers (receipts -> Merkle round root -> ledger state chain):

```
ledger genesis state = 0x54524C47
round0: root=0x12CE67F1 epoch=1 +713 $TRI -> balance=713  state=0x13B889D4
round1: root=0x8ABC1234 epoch=2 +690 $TRI -> balance=1403 state=0x15C4460E
round2: root=0x55AA33CC epoch=3 +705 $TRI -> balance=2108 state=0x64102268
FINAL: node balance=2108 $TRI, ledger state root=0x64102268
tamper round0 root -> state=0x885A0E62 : DIFFERS (tamper caught)
```

A node's $TRI now persists across rounds; the whole history commits to one 32-bit state
root; tampering (or reordering) any past round changes it. ARM == host bit-exact.

## The full DePIN chain now on silicon

relay receipt (Proof-of-Relay, Ed25519-signed) -> integrity gate + FEC + interleaver
for the lossy channel -> quality-weighted payout by MEASURED SNR -> Merkle round root
-> **append-only ledger state chain** (accumulated $TRI). Every layer verified through
the t27 golden pipeline and run on the node ARM.

## Honest boundary

- The hash is the non-cryptographic mix32; a production ledger uses a real hash + the
  Ed25519 signature over the state root.
- No blockchain: the state root is what an on-chain contract would store; here it is
  computed and checked on the node.

No radio touched this wave (pure ledger, host+ARM). Boards left clean: TX LO pd=1.
