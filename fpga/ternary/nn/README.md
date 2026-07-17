# A trained ternary RF classifier, run bit-exact on the hardware MAC

This closes phases 1-4 of the "AI on one chip" plan: a real neural network,
**trained on real over-the-air captures**, whose every layer is provably computed
by our ZeroDSP ternary MAC (`tern_matvec`) -- bit-for-bit identical to the
software reference. The AI is not a slide; the hardware runs it.

## The task and the net

Three-class RF classification from a 27-bin log-magnitude spectrum:
**tone** (narrowband, sharp peak) / **pn** (spread-spectrum, wide) / **off**
(noise floor). All three are real captures (board .13 -> .12). The model is a
tiny ternary MLP:

```
27 features -> [ternary 16x27] -> ReLU+requant(int8) -> [ternary 3x16] -> argmax
```

Every weight is **-1, 0, or +1** (BitNet b1.58 absmean quantization, trained with
a straight-through estimator). Accuracy on held-out windows: **100%** -- and the
integer, hardware-exact forward pass scores **100%** too.

## The hardware proof (phase 4)

`nn_layer_tb.v` loads the trained ternary weights and int8 activations and runs
each layer through the synthesizable `tern_matvec` (0 DSP). The Verilog dot
products are compared to the software reference for 6 held-out samples:

```
layer1 bit-exact match: True  (0 mismatches)   [16 neurons x 27 inputs]
layer2 bit-exact match: True  (0 mismatches)   [ 3 neurons x 16 inputs]
per-sample: tone(ok) tone(ok) pn(ok) tone(ok) tone(ok) pn(ok)
-> the hardware MAC runs the trained ternary net BIT-EXACT
```

## Files

- `nn_layer_tb.v` -- parameterised harness (M, K set via `-P`), reads a weight
  file and an activation file, drives `tern_matvec`, prints the neuron outputs.
- `nn_W1.hex` / `nn_W2.hex` -- the trained ternary weights (one 2-bit code per
  line: `1`=+1, `2`=-1, `0`=0), 16x27 and 3x16.
- `nn_x{0..5}.hex` -- layer-1 input activations (int8) for 6 held-out samples.
- `nn_h{0..5}.hex` -- the corresponding layer-2 activations (post-ReLU/requant).

## Reproduce

```
# layer 1 (16 neurons, 27 inputs)
iverilog -g2012 -P nn_layer_tb.M=16 -P nn_layer_tb.K=27 -o /tmp/l1 \
    nn_layer_tb.v ../tern_matvec.v ../tern_dot27.v
vvp /tmp/l1 +WF=nn_W1.hex +AF=nn_x0.hex     # -> neuron dot products

# layer 2 (3 neurons, 16 inputs)
iverilog -g2012 -P nn_layer_tb.M=3 -P nn_layer_tb.K=16 -o /tmp/l2 \
    nn_layer_tb.v ../tern_matvec.v ../tern_dot27.v
vvp /tmp/l2 +WF=nn_W2.hex +AF=nn_h0.hex
```

The training + feature extraction (PyTorch, BitNet-style ternary QAT) runs on the
host and is not on the build path; the weights it produces are the committed
`.hex`. The forward-pass arithmetic the hardware reproduces:

```
a1 = W1 . x                              # HW layer 1 (tern_matvec)
h  = clip(round(relu(a1)/4), 0, 127)     # SW requant to int8 (the PS does this)
a2 = W2 . h                              # HW layer 2 (tern_matvec)
class = argmax(a2)
```

## What this does and does not prove

DONE: a trained ternary net, on real RF data, computed bit-exact by the
synthesizable ZeroDSP MAC in simulation. The compute is correct and multiplier-
free. NOT yet done (phases 5-7): the PS7/AXI boundary, a loaded bitstream, and
on-board latency/power measurement. The math is proven on the chip's fabric
model; the silicon bring-up remains.
