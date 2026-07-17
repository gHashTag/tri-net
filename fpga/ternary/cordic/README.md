# CORDIC Q15 sin/cos (IGLA-RACE cordic_fixed) -- the non-MAC transformer piece

A transformer needs transcendentals the ternary MAC cannot give: RoPE rotates
each query/key by cos/sin of a position-dependent angle. CORDIC computes cos/sin
with **only shifts and adds** -- no multipliers -- so it completes the
multiplier-free story next to the systolic GEMM.

`cordic.v` -- 16-stage pipelined Q15 CORDIC. Input is a binary angle
(2*pi == 65536), output is cos/sin in Q15. Quadrant fold brings any angle into
[-pi/2, pi/2] (where circular CORDIC converges) and flips the output sign;
outputs saturate at +/-1 to avoid the wrap that otherwise flips cos(0). Latency
18 cycles, one result per clock.

## Verified (iverilog)

Swept 73 angles across the full circle, compared to `$cos`/`$sin`:

```
max error = 0.000245  (8 LSB of Q15)  -- sin/cos correct, zero multipliers
```

## Synthesised (yosys, xc7z020)

~1185 LUT, 400 CARRY4, 852 FDRE, **0 DSP48** -- shift-add only, as promised.

SSOT: t27/specs/igla/race/cordic_fixed.t27, cordic_top.t27. The t27 backend emits
the CORDIC datapath functions but a skeleton top; this is the working, verified
realization mirroring that spec.
