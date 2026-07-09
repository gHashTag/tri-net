# FEC verification coverage

What the FEC arc is verified against, beyond the per-spec `test`/`invariant`
blocks. The property checks run over the `t27c`-generated Rust; the exhaustive
sweeps below are the strongest evidence the arc is correct. Re-run by wiring the
generated modules into `src/lib.rs` under `#[cfg(test)]` and `cargo test`.

## GF(256) field (gf256.t27)

- **Inverse, exhaustive:** `gf_mul(a, gf_inv(a)) == 1` for all 255 nonzero `a`.
- **Commutativity + distributivity:** `gf_mul(a,b)==gf_mul(b,a)` and
  `gf_mul(a, b+c) == gf_mul(a,b) + gf_mul(a,c)` over a dense sweep of `(a,b,c)`
  (steps 5/7/11 across 0..255, ~46k triples).
- **Zero edge (now a spec test):** `gf_inv(0) == 0` by convention -- 0 has no true
  inverse. Divisors in `rs_decode.recover*` stay nonzero because distinct erasure
  locators sum to a nonzero value; the one caller error to avoid is a duplicate
  erasure position.

## Reed-Solomon erasure recovery (rs_decode.t27), RS(6,2), M=4

Round-trip: `encode -> zero the erased positions -> syndromes -> recoverL -> compare`.

- **recover2, exhaustive positions x dense messages:** all 15 position pairs
  C(6,2) x 67,080 messages (m1 step 3, m0 step 5) -- every case restores the two
  erased symbols.
- **recover3, exhaustive positions:** all 20 triples C(6,3) x representative
  messages -- plus 120 fully-random messages/positions in the earlier round-trip.
- **recover4, exhaustive positions:** all 15 quads C(6,4) x representative messages
  -- plus 100 fully-random messages/positions earlier. Full M=4 budget.

## Integration (cross-spec)

- **interleaving scales the guarantee:** a 3-codeword keyframe survives losing L
  whole columns for L in {2,3,4} -- every codeword recovers its L erasures.
- **wire drives recovery:** for every lost-column pair, powers taken only from
  `frag_wire.column_to_power` feed recover2 and restore the symbols.
- **receive path closes:** erasures read from `frag_reassembly` + their wire powers
  recover the keyframe for every lost-column pair.
- **capstone truth:** `fec_capstone.delivered(M,lost)` matches actual recovery over
  60 random keyframes (recover for lost <= M, fail at lost = M+1).
- **fragmentation tiling:** `keyframe_fragment` tiles a keyframe with no gap/overlap
  over all sizes 1..4096 x {64,200,512,1000} payloads.

## Compiler

The generating `t27c` passes its own suite at 1411 passed / 5 baseline failures
(jwt x3, ternary, trit_stdlib) with the 9 codegen-clean fixes; no new regressions.

phi^2 + 1/phi^2 = 3 | TRINITY
