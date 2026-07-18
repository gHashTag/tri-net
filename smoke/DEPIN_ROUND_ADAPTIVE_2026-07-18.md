# Full live DePIN round + adaptive interleaver depth (2026-07-18)

## C: a full multi-node, multi-epoch payout round on real measured links

Measured link quality on the bench (DDS tone + iio_readdev): .13->.11 = 33.8 dB,
.13->.12 = 34.0 dB at TX -10; .13->.12 = 17.7 dB at TX -30; = 5.8 dB at TX -50.
These give three distinct node coverages (34 / 18 / 6 dB) -- three nodes at different
distances from a gateway.

`round` mode on node .12 ARM (tri_settle.t27 maths: round_add over epochs,
snr_to_quality, reward_weighted), pool = 1000 $TRI, 3 epochs each:

| node | epochs | total bytes | measured SNR | quality | $TRI |
|------|--------|-------------|--------------|---------|------|
| 0 | 3 | 60000 | 34 dB | 31 | **713** |
| 1 | 3 | 45000 | 18 dB | 15 | **258** |
| 2 | 3 | 24000 | 6 dB  | 3  | **27**  |

weighted_total = 2,607,000; paid = 998 <= pool. A complete DePIN round: each node's
bytes aggregated across epochs, weighted by its REAL measured coverage, the pool split
proportionally. Best-coverage + most-bytes node earns most; weak+few earns least.

## B: adaptive interleaver depth (tri_ilv.t27)

A node measures its channel's worst burst and picks the interleaver depth to match:
`choose_depth(max_burst)` = max_burst clamped to DEPTH_CAP (64); `depth_survives(D,B)`
= D >= B. 8 invariants. `relayfec3` on node .12 ARM, one burst of 12 datagrams:

| depth | interleaved accepted |
|-------|----------------------|
| fixed D=8  | 48/64 (burst 12 > 8 wraps -> some codewords get 2 errors) |
| adaptive D=choose_depth(12)=12 | **48/48 (all recovered)** |

The adaptive depth survives a burst the fixed depth-8 cannot. (On the static bench the
burst length is a parameter; a real burst-length distribution needs a mobile/fading
channel to measure -- honest boundary.)

## A: OTA byte transfer -- flash-gated

Measured two real links (above). The host DBPSK modem is blocked by the AD9361
TX-datapath sample-mapping (RX frame non-periodic; ruled out gaps + RX tracking in the
prior wave). Closing OTA needs either AD9361 TX-chain reverse-engineering or the PL
DSSS PHY that reached BER=0 in prior work (Loop24) -- the latter requires a PL bitstream
FLASH, which is destructive (Art IV cold-cycle) and needs the user's explicit go and
physical presence at the board. Deferred to that; not attempted non-destructively
further (another host modem would hit the same TX-datapath issue).

Boards left clean: tone off, TX LO pd=1, files removed.
