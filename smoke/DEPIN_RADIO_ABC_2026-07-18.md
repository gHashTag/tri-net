# Radio wave: multi-frame throughput + FEC-over-air + averaging gain (2026-07-18)

Three radio improvements, all on real hardware (.13 TX -> .12 RX, 2.4 GHz, no PL flash).
The demod modem (`relay_meter`, scratchpad Rust, bit-compatible with the BER=0-proven host
prototype) gained an on-node TX generator (`otatx`/`otatxfec`) so TX and RX are the same
binary, and three new modes. The FEC uses the t27 `tri_fec` primitive (`fec_parity4`) pasted
inline (as `tri_depin` is), so the recovery logic is spec-derived, not hand-rolled.

## A -- multi-frame framing: near-continuous throughput

Old link: one frame per capture (burst mode, lots of idle capture around it). New `otarxmulti`
acquires the preamble ONCE, then STEPS by the known frame length (5120 complex samples) like a
real modem clocking out frames -- recovering back-to-back frames from one capture into ONE
aggregated Proof-of-Relay receipt.

TX: 3 distinct frames cyclic (`otatx d0 d1 d2`, period 15360). RX `-s 49152`:
```
frame0..8  corr=0.996..1.000  bytes=...0003/...0001/...0002/...  (cyclic, in order)
OTARXMULTI frames=9 total_bytes=72 dgrams=1 seal=0xF83E9B66   (deterministic across captures)
```
- 9 frames x 8 bytes = **72 bytes recovered per capture, BER=0**, one receipt.
- Frames are packed back-to-back (>90% duty): **~384 kbps sustained payload** (64 payload bits
  / 166.7 us per 128-symbol frame), vs the old ~48 kbps burst.
- **RX overrun ceiling is ~64K samples** -- clean multi-frame demod holds through `-s 65536`
  (4x the old 16384 "safe" size), degrades at `-s 98304`. ~1 in 3 captures still misses on
  acquisition/overrun (a bad capture locks onto noise, corr ~0.1) -- streaming RX is the fix.

## B -- FEC over a lossy link: a lost packet rebuilt from parity

TX: 5 frames where the XOR of all 5 == 0 (4 data + 1 parity via `fec_parity4`, `otatxfec`).
Because the whole set XORs to zero, ANY erased frame equals the XOR of the other four --
recoverable regardless of the cyclic capture rotation. `otarxfec` locks+steps 5 consecutive
frames, erases one (a modeled fade), rebuilds it with the t27 `fec_parity4` over the 4
survivors, and verifies bit-exact.

```
rx frame0..4  corr~1.000  ...4302 / ...4303 / ...4304 / parity(...0004) / ...4301
OTARXFEC erased frame2 (fade) original=5452494e46454304 rebuilt=5452494e46454304 match=true
```
- Reproduced across three captures; the erased frame landed on a different payload each time
  (cyclic rotation) and was recovered **bit-exact every time**.
- This is the "a node loses a whole packet in a fade, the mesh rebuilds it from parity" case,
  now proven on real radio. The within-frame interleaver (`tri_ilv`, verified on the wire in
  earlier waves) is the burst-spreading analog for errors inside one frame.

## C -- averaging processing gain (software preview of DSSS)

TX a single frame cyclic; the RX captures many copies. `otarxavg` folds M aligned copies and
averages the differential statistic before deciding (coherent-ish integration). Sweeping TX
power (frame `54524921deadbeef`, 8-copy average):

| TX hwgain | M=1 BER      | M=8-9 BER |
|-----------|--------------|-----------|
| -30 dB    | 0/64         | 0/64      |
| -40 dB    | 0/64 (corr 0.67 marginal) | 0/64 |
| **-45 dB**| **up to 14/64** | **0/64** (reproduced 4/5; 1 run already clean at M=1) |
| -50 dB    | ~33/64       | ~24/64 (acquisition itself fails, corr 0.004) |

At -45 dB the single-copy link is failing (mean ~6.6 bit errors/64 over 5 runs); 8-9x averaging
drives it to ~0.4/64 -- a real, reproduced processing gain. At -50 dB averaging can no longer
help because the PREAMBLE LOCK fails first: that is exactly the regime where the DSSS spreading
gain in the PL (flash-gated, not done this wave) is required. Honest boundary, honestly placed.

## Debugging lessons this wave (broken-ruler errors caught)

- **`timeout` does not exist in macOS zsh.** Last wave's "ssh daemon down" verdict was a
  self-inflicted broken-ruler error: the ssh wrapper failed on the missing `timeout`, not on
  the boards. All three boards were up the whole time (confirmed: TXpd=1, clean).
- **The TX LO powers DOWN (TXpd->1) when the cyclic writer is (re)started/killed.** A carrier
  that is off makes RX see only noise (corr ~0.13, garbage) -- the received signal lied about a
  "link failure" that was really a powered-down transmitter. Fix: force `TXpd=0` AFTER the
  writer is up, immediately before RX.
- **Greedy global-argmax multi-frame search jumps a full pattern-period under noise** (found the
  same frame every 15360 instead of the neighbour at 5120). Lock the preamble ONCE, then step by
  the known frame length -- standard modem framing.
- **`ps -A | grep -c iio_writedev` over-counts**: the remote command's own text contains the
  string, so grep matches the ssh process itself. Count real writers via `/proc/PID/comm`.

## Flash gate honored

"все три смело" is encouragement, not the safety trigger. The PL DSSS-PHY flash stays gated on
an explicit "прошивай" WITH the user physically at the board (destructive Art IV cold-cycle).
C was delivered as the non-destructive averaging demo instead.

Boards left clean: writers=0, TX LO pd=1 on .11/.12/.13, hwgain restored, IQ files removed.
