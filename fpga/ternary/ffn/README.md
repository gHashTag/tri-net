# Ternary transformer FFN sublayer (IGLA-Coder feed-forward block)

The first real transformer sublayer on our multiplier-free engine. `tern_ffn.v`
computes, in one clocked FSM:

```
y = x + W2 . ReLU(W1 . x)
```

the up-projection `W1` (H x D), the down-projection `W2` (D x H), and the
residual add -- all ternary, all zero DSP (tree `tern_matvec`). Crucially the
**activation (ReLU + requant to int8) and the residual live in the hardware FSM**,
not the PS: the whole sublayer is self-contained. FSM: IDLE -> L1 -> RQ -> L2 ->
RES -> DONE, **4 compute cycles**.

## Verified (iverilog)

An integer, hardware-exact FFN (D=4, H=8, ternary W1/W2, int8 x, S1=S2=3 requant
shifts) matches the numpy reference bit-for-bit:

```
y_hw = [34, 52, 80, -31]  ==  y_ref = [34, 52, 80, -31]   (0 mismatches, 4 cycles)
```

The structure is two `tern_matvec` calls with an activation between; the
`tern_matvec` half is already proven bit-exact at Coder width (768) in
`../nn/README.md` (E3), so the FFN holds at transformer dimensions.

## Resources

Each `tern_matvec` is 0 DSP (balanced-tree `tern_dot27`), so the FFN is **0 DSP**
by construction. Exact post-P&R Fmax at H=32+ is deferred -- nextpnr on two large
combinational tree-matvecs is slow under amd64 emulation on this host -- but the
components P&R at ~36 MHz (the tree-matvec MLP, `../nn`), and the FFN adds only a
5-state FSM around them.

## Where it sits

With the systolic GEMM (`../systolic`, 33 GOPS) and CORDIC RoPE (`../cordic`),
this completes an IGLA-Coder transformer layer's compute on multiplier-free
fabric: FFN here, attention = the same GEMM + CORDIC + a softmax (the remaining
piece). Missing for a full layer: hardware softmax and weight streaming from BRAM
for D_FF=2048-scale layers (tiling).
