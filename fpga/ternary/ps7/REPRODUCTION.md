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

---

## Resolved 2026-08-03: it was a timestamp, and the flow is reproducible

The conclusion above -- that `xc7frames2bit` is nondeterministic and a SHA-256
seal "attests to nothing" -- was based on hashing the whole file. Hashing the
whole file was the mistake.

Two runs on an identical `ps7_corr.frames`:

```
differing bytes: 1
offset 100 (1-indexed): '4' vs '8'
```

One byte. It is the seconds digit of the build time in the header:

```
field 'c' = 2026/08/02        build date
field 'd' = 18:37:14          run A
field 'd' = 18:37:18          run B
```

Skipping the 200-byte header, both payloads hash to
`ad22ca18735dc6ccd649687082390565b0a8944804ceaaa72f44d8c5c9fd36c1`. Every one of
the 4 045 470 configuration bytes -- everything that reaches the silicon -- was
identical all along. The tool stamps the wall clock into a metadata field, which
is the most common single cause of an unreproducible build in any toolchain, and
the standard remedy applies.

`bitcanon.py` pins the two header fields to a fixed epoch. Five consecutive
runs, one second apart:

| | SHA-256, first 16 |
|---|---|
| raw run 1..5 | `c3c63083979d115d` `3cff9d3233a9d3a2` `487d6b999b3a9faf` `0c90507e769cf09f` `20bf14d576d6dce8` |
| canonicalised 1..5 | `6bba2955d5dd6bdb` x5 |

`distinct hashes: 1`.

**The correct claim is now: the open flow is byte-reproducible end to end, and
the seal belongs on the canonicalised bitstream or on the payload hash, not on
the raw file.** Two engineers building the same source do get the same
bitstream. That question is the one defence assurance actually asks, and until
today this project was answering it wrongly against itself.

Reproduce:

```
docker run --platform linux/amd64 -v "$PWD":/work -w /work regymm/openxc7 \
  bash -c 'source /prjxray/env/bin/activate; cd /work; \
  for i in 1 2 3 4 5; do xc7frames2bit \
    --part_file /nextpnr-xilinx/xilinx/external/prjxray-db/zynq7/xc7z020clg400-1/part.yaml \
    --part_name xc7z020clg400-1 --frm_file ps7_corr.frames --output_file run$i.bit; sleep 1; done'
for i in 1 2 3 4 5; do python3 ../bitcanon.py run$i.bit -o c$i.bit; done
sha256sum c*.bit | awk '{print $1}' | sort -u | wc -l    # must print 1
```

---

## Two corrections to this document, 2026-08-03

**The headline Fmax in this file does not match its own log.** The prose above
says "stable at **302.85 MHz**" across five seeded runs and asks that 308 MHz be
re-quoted as 302.85. But `build/REPRODUCTION.log:1790` — produced by
`run_openxc7.sh`, which hard-codes `--seed 1` — reports **308.07 MHz**, and the
string `302.85` appears in no log anywhere in the repository. One of the two is
wrong and the log is the artifact. Until a fresh seeded run settles it, quote
neither.

**The five-run reproducibility demonstration covers one stage, not four.** The
experiment recorded above re-runs `xc7frames2bit` five times on a single
pre-existing `ps7_corr.frames`. That is exactly the right test for the defect it
was chasing, and it settles that stage. It is **not** an end-to-end result, and
saying "the open flow is byte-reproducible end to end" on the strength of it
overstates what was done. The earlier stages were shown byte-stable in the
separate five-seeded-run experiment described at the top of this file.

Two experiments, each sound, joined by inference. The honest sentence is:
*"the final stage is deterministic once the timestamp is pinned, and the earlier
stages were separately shown stable."* A single sweep of five complete builds
would collapse both into one claim and costs nothing but wall-clock.

---

## Settled 2026-08-03: five COMPLETE builds, end to end

The correction above asked for five full builds instead of five runs of the last
stage. Done. `ps7_pn_tree`, `--seed 1`, the whole flow each time:

| Artefact | distinct hashes across 5 full builds |
|---|---|
| `.json` (yosys) | **1 of 5** |
| `.fasm` (nextpnr) | **1 of 5** |
| `.frames` (fasm2frames) | **1 of 5** |
| `.bit` raw | 5 of 5 |
| **`.bit` payload only** | **1 of 5** -- `24e8e27f8518ff41...` |
| `.bit` canonicalised | **1 of 5** -- `8638c6f02a4ac94e...` |

Reported Fmax was 58.36 MHz on every one of the five.

**Three of four stages are byte-identical, and the fourth differs only in
metadata.** The configuration payload -- every bit that reaches the silicon --
is identical across five independent builds from the same source. The claim
"byte-reproducible end to end" is now supported by the experiment it needed.

### A defect in bitcanon.py, found by this experiment

The first attempt at canonicalising the five still gave five distinct hashes.
The cause was in my own tool: `xc7frames2bit` copies its **input filename** into
header field `'a'`, and the five builds wrote `f1.frames` .. `f5.frames`.
`bitcanon.py` normalised the date and time but not the name, so it removed two
of the three sources of variation and reported success on neither.

Fixed: field `'a'` is now pinned as well. The lesson is the one this project
keeps relearning -- a normaliser that is not tested against a genuinely varying
input will silently normalise the wrong things.
