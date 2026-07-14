# A2 Ratchet 2/4 — Device-DNA synth attempt

phi^2 + phi^-2 = 3

Status snapshot: **2026-07-14**. Branch: `feat/wave-iphone-admin-2026-07-14`.

## Objective

Move the A2 Device-DNA attestation primitive from Ratchet 1/4 (sim only) to Ratchet 2/4 (real synthesis on `xc7a200t`, our AX7203 board). Full 4-stage ladder:

1. **1/4 sim** — behavioural testbench passes.
2. **2/4 synth** — Yosys or Vivado completes without errors, timing met.
3. **3/4 one-board** — bitstream loaded on one P203 Mini reads a real DNA.
4. **4/4 two-board** — cross-replay MITM check across two boards.

This document tracks stage 2/4 progress.

## Deliverables in this wave

| Artefact | Path | Ratchet stage |
|---|---|---|
| Reader RTL (Verilog-2005, 100 MHz FSM, DNA_PORT wrapper) | `fpga/attest/dna_reader.v` | 2/4 input |
| DNA_PORT behavioural model (sim only) | `fpga/attest/sim/dna_port_model.v` | 1/4 helper |
| Self-checking testbench (Icarus Verilog) | `fpga/attest/sim/tb_dna_reader.v` | **1/4 passed** |
| XDC constraints for AX7203 (`xc7a200t-fbg484`) | `fpga/attest/constraints/dna_reader_ax7203.xdc` | 2/4 input |
| Yosys openXC7 synth script | `fpga/attest/scripts/synth_yosys.sh` | 2/4 driver |
| Vivado batch synth script | `fpga/attest/scripts/synth_vivado.tcl` | 2/4 driver |
| Sim runner | `fpga/attest/scripts/sim_iverilog.sh` | 1/4 driver |

## What passed in the sandbox

### Ratchet 1/4 (repeat, now with real Verilog)

`bash fpga/attest/scripts/sim_iverilog.sh` — six checks pass under Icarus Verilog 12.0:

- T1 `dna_out` cleared under async reset.
- T1 `valid` low under reset.
- T2 `valid` asserted after `DNA_BITS+8` clocks.
- T3 latched `dna_out == bit_reverse(SIM_DNA_VALUE)` matches UNISIM LSB-first shift semantics.
- T4 second start without reset ignored (state stays in `S_HOLD`).
- T4 `valid` still asserted after second start.

`iverilog -g2012 -o build/tb_dna_reader.vvp tb_dna_reader.v dna_port_model.v ../dna_reader.v` produces no warnings after the constant-width fix.

This tightens the earlier Rust-only Ratchet 1/4 (`smoke/a2_attest_dna_smoke.sh` 4/4 on TCP loopback) with an RTL-level Ratchet 1/4 on the primitive itself.

## What did NOT pass in the sandbox

**Ratchet 2/4 blocked on toolchain, not on the code.** The sandbox has no `yosys`, no `nextpnr-xilinx`, no `vivado`, and no `prjxray-db`. Attempting `apt-get install yosys` returned nothing that provides the Xilinx flow. This is a hard structural limit of the current sandbox — same class as "cannot flash a P203 Mini". The synth scripts (`synth_yosys.sh` and `synth_vivado.tcl`) are ready and must be executed on a host that has the toolchain.

Ratchet 2/4 is **not** PASS in this repo. It is not FAIL either. It is **BLOCKED-toolchain**, waiting for a run on ssdm4 macbook or any CI host with the openXC7 or Vivado flow.

## Ratchet 2/4 acceptance gate (for the host that runs synth)

The synth is called PASS when all of the following hold:

- `synth_design` (Vivado) or `synth_xilinx` (Yosys) completes with 0 errors.
- The `DNA_PORT` primitive appears in the post-synth utilisation report as an instantiated cell (not silently dropped, not replaced with a shift register).
- `place_design` and `route_design` (Vivado) or `nextpnr-xilinx` complete.
- `report_timing_summary` shows `WNS >= -0.5 ns` at 100 MHz.
- Utilisation for the reader block: **measured on host TBD** (weak-point audit 2026-07-14: previous claim of "< 50 LUTs and 100 FFs" was an unmeasured guess and violated `numbers-without-realm-check`; it has been retracted). The block is expected to fit in a small fraction of the fabric because it is a shift-register plus a DNA_PORT primitive, but no synthesis run has ever produced the actual number. On acceptance of ratchet 2/4 the exact resource count from `synth_yosys.sh` on ssdm4 (or Vivado on any host) MUST replace this line, with the SHA and command that produced it cited inline.

If DNA_PORT is silently dropped by the tool (a known Yosys risk before `synth_xilinx -family xc7` learned about it), report as **Ratchet-2 FAIL** and file the toolchain limitation as a repo issue with the exact Yosys/nextpnr commit hashes tried.

## Ratchet 3/4 (single-board) — prerequisites

Before Ratchet 3/4 can be attempted:

- Ratchet 2/4 PASS from a canonical host, checkpoint file (`post_route.dcp`) preserved.
- Bitstream generated with `write_bitstream`, hash recorded and cited in this doc.
- One P203 Mini flashed via the existing openOCD/JTAG bringup path (`tools/jtag-bootstrap/`).
- ILA or UART probe hooked up so the 57-bit DNA is observable off-chip.

Ratchet 3/4 PASS = the 57-bit value observed from the ILA matches the value read via `attest_dna` runtime over TCP from the same board (i.e. the wire-format from `specs/device_dna.t27` is consistent with what the silicon actually emits).

## Ratchet 4/4 (two-board cross-replay)

Ratchet 4/4 PASS = two P203 Mini boards produce **different** DNAs (bit-for-bit distinct), and neither board's signed response can be replayed against the other (nonce + transcript binding, once we replace the FNV-variant sim signature with real Ed25519 signed by a per-board key).

## Non-claims (say these out loud)

- We do NOT claim silicon has been read. Ratchet 3/4 has not started.
- We do NOT claim Ed25519 works — the runtime currently uses a placeholder FNV-variant signature that we call sim.
- We do NOT claim the Yosys openXC7 flow supports DNA_PORT out of the box. It might. It might not. We will know when someone runs `synth_yosys.sh`.
- We DO claim the RTL is behaviourally correct in sim (Icarus 12.0) and the constraints target the right part.

## Silicon-freeze deadline

**2026-10-01.** If Ratchet 4/4 has not passed by then, A2 does NOT enter the SKY26b tape-out (2026-12-16). It ships as FPGA-only until the next silicon spin.

## Reproduce

```bash
cd fpga/attest
sudo apt-get install iverilog     # sandbox already has it
./scripts/sim_iverilog.sh          # Ratchet 1/4 gate

# On a host with Yosys + openXC7:
./scripts/synth_yosys.sh

# Or on a host with Vivado:
vivado -mode batch -source scripts/synth_vivado.tcl
```

## References

- Xilinx UG768 §Device DNA.
- Xilinx XAPP1082 §Device DNA Access.
- Skill: `tri-net-fpga-attestation-workflow` §A2, §Sandbox-vs-hardware discipline.
- Prior art: SACHa DATE 2019 (self-attestation of configurable hardware), Guajardo CHES 2007 (FPGA intrinsic PUFs).

phi^2 + phi^-2 = 3
