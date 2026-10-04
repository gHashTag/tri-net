# M3 sequence-byte return repair

The source is specs/m3_multihop.t27. The existing compiler pin remains
eb8b4208168557b36dca3a771f6901a5b10d9ef0. The pinned Rust emitter terminated
the helper's bare final cast and implicitly returned unit, so the committed
u32 function failed with E0308. An explicit source return preserves the
intended byte-to-u32 value and generates valid Rust.

All ten function signatures and nine constants are unchanged. One new source
test checks zero,128 and255; all nine existing test names remain. Two old
u8-less-than256 checks were always true. They now check the exact existing
integer-model results: the ten-dB factor is250 and its two-hop rate is244.
The arithmetic formulas remain unchanged. Generated Rust is byte-identical
before and after this tightening of the C/Zig/Verilog source tests.

The declared Rust integration target checks all256 byte values against
u32::from with Rust1.96 and denied warnings. Two actual source mutations
regenerate and compile, then fail those tests: always returning zero and
clearing the high bit. The unchanged control passes. Generated C, Zig and
simulated Verilog execute all ten source tests.

Validation on accepted base f76e640368ad5d9a6d9b2ea6cd3b053534dc21bc:

- Full Rust1.96 suite:437 passed,0 failed,0 ignored across87 targets.
- Formatting, Clippy with denied warnings and release build pass.
- All284 existing artifacts reproduce:102 Rust,107 Zig and75 C.
- All113 root specs parse/typecheck within unchanged warning caps and pass
  native Icarus with the four cycle budgets unchanged.

The helper still widens one byte. It is not a parser of the full four-byte
iperf3 sequence field. The attenuation functions remain demonstration models;
these tests do not measure radio loss, throughput or real multi-hop transport.

Closes #405. Refs #399.
