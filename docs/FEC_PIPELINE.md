# FEC pipeline: resilient video keyframes over lossy mesh radio

A spec-first forward-error-correction subsystem that lets a video keyframe survive
fragment loss on a drone-mesh link. Thirteen `.t27` specs, each generated to Rust
(host) and Verilog/C/Zig (FPGA) by `t27c`, machine-verified by property tests over
the generated code. This document maps the arc so it can be reviewed and landed as
one unit.

## Problem and approach

A keyframe (I-frame) is large and self-contained: losing part of it corrupts the
whole GOP. Over a lossy radio, some fragments will not arrive. The subsystem:

1. picks the modulation from link SNR (throughput follows quality),
2. chooses how much Reed-Solomon parity to spend from that SNR and the frame's
   criticality,
3. fragments the keyframe, RS-encodes it, and interleaves so a burst loss becomes
   distributed single-erasures,
4. carries each fragment in a wire format whose header tells the receiver exactly
   how to recover it,
5. reassembles on the receive side and RS-decodes the erased fragments.

Because fragments are AEAD-protected at the transport, a corrupted fragment fails
its tag and is simply absent -- so this is **erasure** decoding (lost positions
known), not error correction. That is the exact, cheap case; no Berlekamp-Massey.

## Pipeline

```
  SNR ---> adaptive_mcs ---> modulation
                 |                 |
                 v                 v
  is_keyframe -> adaptive_fec ---> M parity      keyframe bytes
                       |                               |
                       v                               v
                  fec_capstone <--------------- keyframe_fragment (K data)
                       |                               |
                       |            rs_generator       v
                       |                 |         rs_encode (K -> K+M per codeword)
                       |                 v             |
                       |               gf256           v
                       |                          rs_interleave (C codewords, columns)
                       |                               |
                       |                               v
                       |                          frag_wire (column j -> power N-1-j)
                       |                               |
                       |                        [ radio: lose <= M columns ]
                       |                               |
                       |                               v
                       +---- delivered(M,lost) --> frag_reassembly (bitmap, >= K)
                                                       |
                                                       v
                                                  rs_decode.recover2/3/4 -> keyframe
```

## Module map (13 specs)

**Link adaptation**
- `adaptive_mcs` -- SNR -> MCS with hysteresis (BPSK+FEC / BPSK / QPSK); EWMA SNR.
- `snr_feedback` -- receiver reports far-end SNR in HELLO; quantize/dequantize.
- `mcs_mode_header` -- per-frame modulation mode-header with 8x repetition code.

**Reed-Solomon core (GF(256), RS(6,2) demo codeword, 4 parity)**
- `gf256` -- table-free field: gf_add(XOR), gf_mul (carryless), gf_pow, gf_inv=a^254.
- `rs_generator` -- generator polynomial g(x), roots alpha^0..alpha^3; gen_eval.
- `rs_encode` -- systematic encode via LFSR division by g (state packed in u32).
- `rs_decode` -- erasure recovery: recover2/recover3/recover4 (full M=4 budget),
  Lagrange / inverse-Vandermonde form; syndrome6.

**Policy, scaling, transport**
- `adaptive_fec` -- parity_for / parity_for_snr: how many parity symbols to spend.
- `keyframe_fragment` -- byte-level layout: K = ceil(bytes/payload), offsets, tail.
- `rs_interleave` -- lay a keyframe as C codewords, transmit by column, so a lost
  fragment is one erasure per codeword -> the whole keyframe inherits the M budget.
- `frag_wire` -- on-air header (u32: keyframe_id | column | codeword_count | flags);
  column_to_power links a wire column to the RS power recover* needs.
- `frag_reassembly` -- receive bitmap of arrived columns; should_decode (>= K);
  nth_erased_column enumerates erasures for recover*.

**Capstone**
- `fec_capstone` -- plan_parity / plan_coded_fragments / delivered(m,lost)=lost<=m;
  composes AdaptiveFec (and AdaptiveMcs) + KeyframeFragment.

## Machine-verified integration invariants

These are the cross-spec properties the property tests prove, not just assert. They
are what makes the composition trustworthy:

- **Field:** gf_mul(a, gf_inv(a)) == 1 for all 255 nonzero a.
- **Encode:** a systematic codeword evaluates to zero at every generator root
  (verified over random messages).
- **Decode round-trip:** encode -> erase L symbols -> recover with recoverL restores
  the originals, for L in {2,3,4} over many random messages and positions.
- **Interleaving scales the guarantee:** on a multi-codeword keyframe, losing L whole
  columns recovers every codeword's L erasures -> the whole keyframe returns
  (L <= M), any keyframe size.
- **Wire drives recovery:** for every lost-column pattern, the erasure powers taken
  ONLY from frag_wire.column_to_power feed recover* and restore the symbols.
- **Receive path closes:** the erased columns read from frag_reassembly + their wire
  powers recover the keyframe for every lost-column pair.
- **Capstone truth:** delivered(M,lost) matches reality -- recovery succeeds iff
  lost <= M (verified against actual recover2/3/4 over random keyframes).

## Scale

The RS core is a small demo codeword RS(6,2): K=2 data + M=4 parity. Real keyframes
are hundreds of symbols. `rs_interleave` scales it without needing arrays (a t27
limitation): a keyframe is C = ceil(D/K) codewords transmitted column-interleaved,
and the M-erasure guarantee lifts to the whole keyframe regardless of size. A future
step is a larger K per codeword to cut the parity overhead (RS(6,2) is 200% for the
demo K; RS(255,251) is ~1.6%).

## Boundaries

- Error correction is intentionally absent: AEAD turns corrupted fragments into
  erasures, so erasure decoding covers the mesh case.
- Byte<->symbol mapping and daemon wiring (receive buffers per keyframe_id, feeding
  the transport) are not yet specified.
- All logic is generated from the specs; `gen/` is rebuilt by build.rs. The specs
  and the 9 pending `t27c` codegen fixes live on the `codegen-clean` branch and are
  not yet resealed/merged to master (see the audit in the t27 repo,
  `docs/PARSE_SILENT_DROP_AUDIT.md`): landing them is a coupled reseal step.

phi^2 + 1/phi^2 = 3 | TRINITY
