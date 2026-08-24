# ps7_tern reproduced through the open flow — and the flow is not byte-reproducible

**Date:** 2026-07-31
**Host:** Apple Silicon (arm64) running the x86_64 toolchain under emulation
**Container:** `regymm/openxc7` (11.3 GB), Yosys 0.62 (git sha1 `7326bb7d6`), nextpnr-xilinx `45a986b`
**Reproduce with:** [`build/run_openxc7.sh`](build/run_openxc7.sh), full log in `build/REPRODUCTION.log`

Until today the numbers in this directory's README came from one local run that was never
recorded. They are now reproduced from a clean machine that had none of this toolchain
installed. Two matched exactly, one did not, and the run exposed a defect in the flow that
matters more than the artifact.

## Matched

| Quantity | README | Reproduced |
|---|---|---|
| Bitstream size | 4 045 670 bytes | **4 045 670 bytes** |
| Frames | 7802 | **7802** |

This also settles a discrepancy between two files in this repository: `ps7/README.md` said
4 045 670 and `fpga/ternary/README.md` said 4 045 664. The former is correct.

## Did not match: Fmax is run-dependent

`fpga/ternary/ps7/README.md` records **Fmax `FCLKCLK[0]` = 308 MHz**. Across runs without a
fixed seed the value ranged **180.15 … 308.07 MHz**. The recorded 308 MHz was a fortunate
unseeded run, not a property of the design.

With `nextpnr-xilinx --seed 1` the value is stable at **302.85 MHz**, identical across five
consecutive runs. That is the number that should be quoted, with the seed stated alongside it.

## The finding that matters: the last stage is not byte-reproducible

Five consecutive runs with `--seed 1`, hashing every intermediate artifact:

| Artifact | Producer | SHA-256 (first 12) | Stable? |
|---|---|---|---|
| `ps7_tern.json` | yosys | `5ffccf2384e9` | yes |
| `ps7_tern.fasm` | nextpnr-xilinx | `bd3fad0ac8d0` | yes |
| `ps7_tern.frames` | fasm2frames | `8b2b469aa70e` | yes |
| `ps7_tern.bit` | **xc7frames2bit** | **differs every run** | **no** |

Synthesis is deterministic. Place-and-route is deterministic given a fixed seed. Frame
generation is deterministic. The final stage produces **different bytes from identical
input**.

The consequence is direct and unflattering: a SHA-256 seal on the bitstream currently
attests to nothing. This repository's central claim is a spec-first pipeline verified
bit-exactly at every level, and the last link of its own hardware flow does not hold that
property. The defect is isolated to one tool and looks like a timestamp or an unordered
container traversal; it is diagnosable and probably fixable.

Note the shape of the result: three of four stages are reproducible and the failure is
localised. This is what a conformance procedure is supposed to do — find the one link that
does not hold, rather than assert that all of them do.

## Two environment defects, both worked around

1. `/prjxray/database/zynq7` inside the image contains only `settings.sh`. The usable
   database is at `/nextpnr-xilinx/xilinx/external/prjxray-db/zynq7`. Pointing `fasm2frames
   --db-root` at the first path fails with `Mapping file .../mapping/devices.yaml does not
   exist`.
2. `xc7frames2bit` requires `--part_file <db>/<part>/part.yaml`. Without it the tool exits
   with `Part file not found or invalid`, which does not indicate the missing argument.

Both are handled in `run_openxc7.sh`.

## What this does and does not establish

**Establishes:** the fully open flow (yosys → nextpnr-xilinx → fasm2frames → xc7frames2bit)
reaches a loadable xc7z020 bitstream from this source on a machine provisioned from scratch,
and the run is recorded and repeatable.

**Does not establish:** anything on hardware. No bitstream has been loaded into a PL on any
Puzhi Mini board. The pin and PS-side work described in the "Honest boundary" section of the
README remains undone.

## Next

- Find the source of nondeterminism in `xc7frames2bit` and either fix it or record the flow
  as reproducible only up to `.frames`.
- Re-quote Fmax as `302.85 MHz (--seed 1)` wherever `308 MHz` appears.
- The hardware step is a separate piece of work with its own preconditions.

`phi^2 + phi^-2 = 3`
