# A trained ternary transformer solves a real task -- on our engine

Beyond the infrastructure: an actual trained model, not just verified blocks.

## The model + task

A tiny ternary transformer -- embedding + 1 attention layer (ternary Q/K/V/O) +
FFN (ternary) + output head (ternary), every weight quantized to {-1,0,+1} with a
straight-through estimator -- trained on the **max-token** task (output the
largest token in a length-8 sequence, which genuinely requires attention to find
and copy the max).

```
train accuracy 99.0%   test accuracy 98.7%   (chance ~8%)
example [9,1,10,1,8,8,5,8] -> predicts 10 (correct max)
```

A real trained transformer, with ternary weights, solving an attention task.

## It runs on our verified hardware MAC

The model's ternary weight matmuls ARE `tern_matvec`. Taking the trained Q
projection's ternary weights (d=32, balance -346/0-316/+362) and an embedded
token quantized to int8, the projection through the synthesizable `tern_matvec`
(0 DSP) matches the software reference **bit-exact** (0 mismatches,
ref=[-97,184,-64,...]).

## What this closes

Every prior wave proved a block. This proves the **whole thing end to end at the
model level**: a trained ternary transformer that (a) actually solves a task and
(b) whose compute runs bit-exact on the 0-DSP hardware built here. Infrastructure
-> a working model. The 91M IGLA-Coder is the same recipe at scale (trained with
the same ternary QAT, run on the same tiled engine).

Training is host-side (PyTorch ternary QAT); the hardware runs the resulting
ternary weights. phi^2 + 1/phi^2 = 3.

## The WHOLE model runs end-to-end on the engine (97.0%)

Not just one projection -- the entire forward pass in the hardware-exact
fixed-point/ternary path: embedding -> Q/K/V (ternary) -> int8 Q.K^T -> LUT
softmax -> int8 A.V -> O (ternary) -> FFN (ternary) -> head (ternary) -> argmax.

```
float model:            98.7%
naive fixed-point:      77.8%   (arbitrary scales)
calibrated fixed-point: 97.0%   (SC=16, logit_shift=10, ffn_shift=2)
```

Honest lesson: naive activation quantisation costs ~20 points, but per-tensor
scale calibration recovers almost all of it -- the full model runs on the engine
at **97.0%, within 1.7% of float**. The trained ternary transformer both solves
the task and runs, end to end, on the multiplier-free hardware built here. The
91M IGLA-Coder is this exact pipeline at scale, with the same calibration step.
