# Merkle settlement commitment + 3-node relay + OTA config-read (2026-07-18)

## B (closed): Merkle commitment over the payout round (tri_merkle.t27)

An off-chain settlement is unverifiable -- a node can't prove it was paid correctly,
and no one can audit the round. Fix: the settler publishes ONE Merkle root over all
nodes' (receipt, reward) leaves; each node claims its reward with a logarithmic
inclusion proof. This is Helium's exact model (store the root on-chain, claim by a
Merkle proof; -99.9% identity cost).

`specs/tri_merkle.t27` (depth-3, 8 leaves, unrolled since t27 has no loops):
`leaf_hash`, `merkle_root8`, `merkle_step`, `merkle_verify8`, order-sensitive `hpair`.
6 invariants (valid proofs at idx 3 & 5, forged reward rejected, tamper-evident root,
wrong sibling rejected). `merkle` mode on node .12 ARM over the real payout round:

```
ROUND ROOT (published on-chain) = 0x12CE67F1
node0 (60000B, q31, 713 $TRI) proof -> VALID (reward claimable)
node0 forges 999999 $TRI       -> REJECTED (root doesn't match)
node2 (24000B, q3, 27 $TRI) proof -> VALID
```

The whole round commits to one 32-bit root; a node proves its reward with 3 sibling
hashes; inflating the reward breaks the proof. ARM == host.

## C (closed): live 3-node relay chain .11 -> .12 -> .13

Real network relay over HTTP (busybox httpd + wget): .11 serves the payload, .12
fetches it, meters what it relayed, and re-serves it; .13 fetches from .12 and meters.
Both relay nodes' receipts are BIT-EXACT identical:

```
.12 receipt: total_bytes=21820 acc=0xBB6CEDC1 seal=0x6EAC3F90
.13 receipt: total_bytes=21820 acc=0xBB6CEDC1 seal=0x6EAC3F90   -> MATCH
```

A real multi-hop relay: the bytes traversed three nodes over the wired network and
each node independently produced the same receipt over what it forwarded.

## A: OTA config-read (RTFM) -- ruled out configured resampling

Read the AD9361 TX datapath config (doctrine: RTFM before reverse-engineering): TX DAC
rate 30.72 MHz, RX rate 30.72 MHz, DDS-core rate 30.72 MHz, TX FIR DISABLED, RF BW 18
MHz. No configured resampling anywhere -- so the OTA frame non-periodicity (autocorr
~0.03 at the frame length) is a DMA/buffer-playout issue, NOT a rate/FIR resample.
Narrows the remaining hunt to DMA-level (underrun/alignment) or the PL DSSS PHY. Still
flash-gated for the real close.

## Note / lesson

While cleaning up, a `grep -E "iio_"` pattern matched the system daemon `iiod` and it
was killed; restarted it (`/usr/sbin/iiod -D -n 3 -F /dev/iio_ffs`). Board sysfs is
kernel-level and was unaffected. Use `[i]iod` / word-anchored patterns near system
process names.

Boards left clean: TX LO pd=1 on .11/.12/.13, files removed, iiod restored.
