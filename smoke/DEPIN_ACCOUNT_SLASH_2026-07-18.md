# Account balance proof + slashing (2026-07-18)

The DePIN account layer now closes two gaps: a node can PROVE its own $TRI balance from
one state root, and a node that lies LOSES a bond (not just a reward).

## B: Merkle account tree + balance inclusion proof (tri_merkle.t27)

`account_leaf(node_id, balance)` -- the ledger state is a Merkle tree over per-node
balances (like Helium's account model). A node proves its OWN balance with a
logarithmic inclusion proof; it cannot claim a balance it does not have. `account` mode
on node .12 ARM:

```
LEDGER STATE ROOT (accounts) = 0x7268C646
node0 proves balance 2108 $TRI -> VALID
node0 forges 999999 $TRI       -> REJECTED
```

## C: bond + slashing (tri_slash.t27) -- the game-theoretic backstop

Rewarding honest work is only half of it; a node must LOSE something for lying. Each
node posts a bond; when its signed receipt fails an independent re-verification (the
settlement re-meters the same stream and recomputes the seal, as the bit-exact 3-node
relay demo does), the bond is forfeited from its $TRI balance. `slash` mode on ARM:

```
start balance=1000 reward=713 bond=100
honest (receipt matches) -> balance=1713 (+reward)
cheat  (receipt mismatch) -> balance=900  (-bond, no reward)
=> cheating < honest, and worse than doing nothing (900 < 1000)
```

Now an honest receipt is the dominant strategy. 6 invariants (honest paid, cheat
slashed, cheating strictly worse, slash saturates at 0, bond gate, receipt matcher).

## A: OTA dmesg diagnostic (non-destructive) -- ruled out a loud underrun

`dmesg` on .12/.13 shows NO DMA underrun/overflow/overrun from any prior TX/RX. So the
frame non-periodicity is NOT a loud DMA underrun the kernel flags -- it is a silent
sample-mapping/timing behavior in the AD9361 TX datapath. Combined with the earlier
config-read (all 30.72 MHz, FIR off), the hunt is narrowed to silent DMA/timing;
closing it needs DMA-level tracing or the PL DSSS PHY. Still flash-gated. (Aside:
cf_axi_adc probes as "AD9364" while cf_axi_dds probes as "AD9361" -- same AD936x die,
driver default naming.)

## The DePIN stack is now complete end-to-end (all on t27 + node ARM)

signed Proof-of-Relay receipt -> integrity gate + FEC + interleaver (lossy channel) ->
SNR-weighted payout -> Merkle round root -> append-only ledger state chain -> per-node
Merkle account (balance proof) -> bond/slashing. Reward for honest work AND punishment
for lying, all verifiable from small roots and proofs.

No radio transmitted this wave (dmesg read-only + host+ARM t27). Boards left TX off.
