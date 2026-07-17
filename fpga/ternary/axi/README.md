# The ternary despreader as an AXI4-Lite peripheral (Zynq PS bridge)

`tern_corr8_axi.v` wraps the ZeroDSP ternary matched filter as an AXI4-Lite
peripheral, so on the P201Mini the **Zynq PS configures it and reads results**
over the same CSR aperture the t27 BitNet accelerator uses. This is the missing
deployment bridge: our radio DSP stops being a standalone RTL toy and becomes a
PS-controlled block.

## Control vs data plane

- **Control plane (AXI4-Lite):** the PS writes the reference code and reads the
  correlation peak. Low rate, register access.
- **Data plane (`s_valid`/`s_data`):** the sample stream comes straight off the
  AD9361 in the PL and never touches AXI-Lite. That split is the whole point --
  AXI-Lite would throttle a 30.72 MSPS stream.

## Register map (reuses the t27-generated `axi_lite_slave`)

| offset | reg          | dir   | meaning                                            |
|--------|--------------|-------|----------------------------------------------------|
| 0x00   | `reg_ctrl`   | write | `[15:0]` eight 2-bit ternary taps; `[16]` load pulse (0->1 latches the code); `[17]` clear peak |
| 0x04   | `reg_status` | read  | sign-extended running peak of the correlation      |

The AXI handshake module is **generated**, not hand-written -- its SSOT is the
t27 spec. Regenerate the dependency with:

```
t27/target/release/t27c gen-axi-lite-slave > axi_lite_slave.sv
```

(That file is NOT committed here; this repo owns only the wrapper that maps our
datapath onto its registers.)

## Verified (iverilog)

`tern_corr8_axi_tb.v` drives the peripheral exactly as the PS would: AXI-write
the reference code + load pulse to `reg_ctrl`, stream a matched burst on the data
plane, AXI-read the peak from `reg_status`:

```
AXI read reg_status (peak) = 600  (want 600)
AXI-LITE DESPREADER: PS wrote code, streamed samples, read peak -- bridge works
```

## Synthesised (yosys, xc7z020)

The whole peripheral (AXI slave + tap-loader FSM + streaming correlator +
peak-hold) is **~847 LUT, 164 FF, 0 DSP48** -- a deployable PS-controlled block
with room to spare beside the AD9361 datapath.

### Two wrapper bugs found and fixed (both silent)

- **Tap loader must drive the config port from REGISTERS, not combinationally.**
  A registered loader FSM (c_wr/c_addr/c_data as flip-flop outputs) is stable
  when the correlator samples it next clock -- the same posedge race that dropped
  even taps in the bare testbench, avoided here by construction.
- **Peak-hold must not gate on `m_valid`.** The aligned correlation lands one
  clock after the last valid sample (pipeline flush), so an `m_valid` gate reads
  a mid-ramp value (measured 300 instead of 600). Track `m_data` every cycle;
  idle `m_data` holds its last value and never beats a real peak.

## Related t27 findings from this study

- **BitNet accelerator P&R (xc7z020):** the full `gen-bitnet-bundle` engine
  (engine_top + AXI-Lite + DMA + weight-prefetch + BRAM + sequencers + IRQ)
  place-and-routes at **0 DSP, ~248 LUT skeleton, Fmax 202 MHz**. The control /
  dataflow infrastructure fits and is fast; the PE array scales with parameters.
- **VSA RF classifier (numpy prototype over real OTA captures):** hyperdimensional
  encoding (D=2048 bipolar, bind=multiply, bundle=majority, hamming similarity)
  detects our tone cleanly (self-similarity 0.96) and tolerates **45% of its
  hypervector bits flipped** while still classifying correctly -- the HDC noise
  robustness that suits a jammed RF edge. Fine 3-way tone discrimination was 67%;
  the feature encoding needs refinement. The HW ops are XOR/majority/popcount
  (t27 `gen/verilog/vsa/ops.v`) -- zero DSP.
