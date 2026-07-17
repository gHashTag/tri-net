# RMSNorm with a ROM rsqrt -- the last transformer-layer block

`tern_rmsnorm.v` computes `y_i = x_i / sqrt(mean(x^2))` (the LLaMA/BitNet
normalisation, IGLA-Coder `RMS_NORM_EPS`). The inverse square root is a
4096-entry ROM -- **no multiplier, no Newton iteration**, the non-MAC primitive
like CORDIC for sin/cos.

## Verified (iverilog)

Input `[40,-70,15,90,-30,55,-12,25]`, N=8, Q6 output:

```
ss=19519  ms=2439  inv=rsqrt[2439]=83 (Q12)
y = [51,-91,19,116,-39,71,-16,32]   bit-exact vs the fixed-point reference
output RMS = 0.997   (RMSNorm target ~1.0 -- it really normalises)
```

## DSP (honest)

The **rsqrt ROM is 0 DSP**. But the sum-of-squares (x_i^2) and the final scale
(x_i * inv) are activation x activation, so they need multipliers -- RMSNorm is a
data-dependent op like attention's Q.K^T / A.V, not a ternary-weight matmul. Small
(N squares + N scales per vector). Debug note: `x_i*x_i` on 8-bit operands
truncates to 8 bits (40^2 read as 64) -- widen to a 2W intermediate first.

## The layer is now complete

With this, every block of an IGLA-Coder transformer layer is built and verified:
RMSNorm (here), attention head (../attn), FFN (../ffn), RoPE (../cordic), softmax
(../softmax), GEMM + tiling (../systolic). Weight matmuls at 0 DSP; the
data-dependent ops (attention products, RMSNorm squares) on a small int8/DSP
slice. A full layer is now an assembly of proven parts.
