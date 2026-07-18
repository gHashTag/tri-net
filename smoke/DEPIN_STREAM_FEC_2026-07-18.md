# Interleaved streaming FEC over the air (2026-07-18)

Last wave's continuous stream exposed the raw link frame-error rate (1-40% drops, no averaging).
This wave adds interleaved forward error correction so a lossy stream self-heals: dropped frames
are reconstructed from parity, taking ~90% delivery up to ~99.5%.

## Scheme (t27 fec_parity4, rate 4/5, interleaved)

- Data frame value = f(seq) = seq * 2654435761 (so parity is non-trivial and every recovery is
  verifiable: recovered value must equal f(recovered seq)).
- Every block of 4 data frames gets 1 parity frame = `fec_parity4` of the four values (the t27
  primitive). If a block loses exactly ONE data frame, it is reconstructed from parity + the 3
  survivors -- `fec_parity4` of the four present frames.
- **Interleaved** in super-blocks of 20: transmitted column-major so a burst of up to 20
  consecutive drops hits at most one frame per block (single-erasure-per-block is exactly what
  the parity repairs), and each block's data+parity fall within one RX capture.
- `otatxstreamfec <ndata>` / `otarxstreamfec <key> <epoch> <nframes>`.

Verified on the host first: zeroing frames in the IQ dropped 2 data frames; FEC healed both and
the receipt seal matched the clean stream bit-for-bit.

## Over the air (.13 -> .12, one 500-frame period per capture)

```
run1:  data_raw=358  +FEC_healed=40 -> data_final=398/400   drops_left=2    (89.5% -> 99.5%)
run2:  data_raw=398  +FEC_healed=2  -> data_final=400/400   drops_left=0    (100%)
run3:  data_raw=387  +FEC_healed=8  -> data_final=395/400   drops_left=5
```

FEC healed up to **40 dropped frames in a single capture**, taking a 42-drop period to 2. The
few remaining drops are blocks that lost >=2 frames -- the honest limit of a single-parity (rate
4/5) code; interleaving spreads the losses so MOST blocks lose <=1 and are recoverable.

## Scientific picture

Last wave the stream was a live broadcast you heard warts-and-all -- every dropped word left a
gap. FEC adds a spoken checksum after every four words: "...and the four were A, B, C, D --
whose XOR is P". If you miss ONE of the four, P plus the other three tells you exactly what it
was. Interleaving is the trick that makes it work against real fading: instead of grouping four
neighbours (a fade takes them all), the four members of a group are spread far apart on the air,
so a burst of static blanks at most one member of each group -- precisely the one the checksum
can rebuild. Cost: one extra frame in five (20% overhead) buys ~90% -> ~99.5% delivery.

## Honest boundary

- Single-parity per block repairs at most ONE erasure per block; blocks with >=2 losses remain
  dropped (needs a stronger code -- e.g. two parities, or RLNC -- for heavier loss).
- 20% overhead (rate 4/5). Adaptive rate to the measured FER is a follow-on.
- Stream repeated to keep it on air for a full-period capture; the FEC math and the t27 primitive
  are the point.
- DSP mod/demod is scratchpad Rust in relay_meter; the receipt it seals IS t27 (tri_depin), and
  the parity uses the t27 tri_fec `fec_parity4`.

Boards left clean: writers=0, TX LO pd=1 on .10/.11/.12/.13, IQ removed.
