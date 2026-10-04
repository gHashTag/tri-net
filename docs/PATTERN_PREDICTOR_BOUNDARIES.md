# Pattern predictor boundary contract

The source is specs/pattern_predictor.t27. Rust, C and Zig artifacts are
generated from it with the existing compiler pin
eb8b4208168557b36dca3a771f6901a5b10d9ef0. This repair does not change that pin.

The sixteen stored samples contain byte values. Requested windows are clamped
to sixteen; an empty mean, variance or prediction returns zero. Every selected
sample contributes once. The mean is rounded down to an integer, variance uses
squared deviations from that integer mean, and the final quotient is rounded
down. This preserves integer arithmetic rather than claiming exact real-valued
population variance.

Trend direction compares the first and last selected values with a five-unit
threshold. Downward predictions subtract ten with a floor of zero. Increasing
predictions keep their existing u32 result, including 255 + 10 = 265.
Public function types, sample packing and repeating-pattern detection are
unchanged.

Four new source tests cover empty, partial, oversized and extreme windows.
All sixteen existing source tests remain. Generated C and Zig each execute all
twenty source tests. Rust integration tests compile the generated module and
compare 65,536 endpoint pairs and 5632 vector-window cases to independent wide
and signed arithmetic. Cargo declares the target explicitly because automatic
test discovery is disabled.

Validation completed for this repair:

- Cargo1.96 full suite:436 passed,0 failed,0 ignored across86 targets.
- Cargo formatting and Clippy for all targets with denied warnings pass.
- All284 committed backend artifacts reproduce under the unchanged compiler.
- Five real source mutations regenerate and compile, then fail the reference
  tests: missing empty guard, unsigned trend subtraction, missing prediction
  floor, four-term variance and an incorrect window clamp.

Clang runtime tests use the compiler's supported formatting-only
Wno-parentheses-equality flag for the existing C emitter's double parentheses;
arithmetic warnings remain errors. Rust checks do not allow unused comparisons
or unused assignments.

The old source fails eleven of thirteen focused boundary checks, including
five arithmetic panics. This repair covers software arithmetic. It does not
establish a radio link, restore the other generated modules in issue399, or
complete hardware verification.

Closes #401. Refs #399.
