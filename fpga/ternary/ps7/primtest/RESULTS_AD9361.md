# Can the AD9361 datapath be rebuilt without Vivado? A bounded answer.

The question that gates the whole product plan: putting our correlator inside
the live AD9361 receive path means rebuilding ADI's `axi_ad9361` through
yosys / nextpnr-xilinx / prjxray. Nobody had checked whether that is possible.

## What the ADI source actually requires

Fetched `analogdevicesinc/hdl` (sparse, shallow -- 2.9 MB) and read it.

**`library/axi_ad9361/` instantiates zero Xilinx primitives.** All eight files
are portable RTL. Its dependencies are ordinary modules in `library/common`
(`ad_datafmt`, `ad_dds`, `ad_iqcor`, `up_axi`, `up_adc_channel` and eleven
others), and `library/common` contains no primitives either.

**Every device-specific primitive is confined to `library/xilinx/common/` --
thirteen files.** Counted across them:

| Primitive | uses | status in openXC7 |
|---|---|---|
| `BUFG` | 17 | **passes** (used in the PLLE2 and MMCM probes) |
| `IDELAYCTRL` | 15 | **passes** |
| `IDELAYE2` | 2 | **passes** |
| `IBUFDS` | 2 | **passes** (full flow to `.bit`) |
| `ISERDESE2` | 1 | **passes** |
| `OSERDESE2` | 1 | **passes** |
| `IBUFGDS` | 2 | **no bels of that type in the chipdb** |
| `BUFIO` | 1 | **no bels of that type in the chipdb** |
| `BUFR` | 1 | **untested; same family as BUFIO** |
| `MMCME2_ADV` | 1 | **fails on a prjxray bit collision** |
| `OBUFDS` | 1 | untested alone (blocked behind IBUFGDS in the probe) |
| `DSP48E1` | 1 | untested; only in `ad_mul.v` |

## The verdict

**Six of the primitives the AD9361 path needs are proven to build end to end.
Four are not, and each has a cheap substitution.**

- `IBUFGDS` -> **`IBUFDS`**. Functionally the same buffer on a clock-capable
  pin; `IBUFDS` already builds to a loadable bitstream here. A one-line edit.
- `BUFIO` / `BUFR` -> **`BUFG`**. Regional clock buffers replaced by a global
  one. This costs clock-domain flexibility and some skew margin, and on a
  design that runs the AD9361 bus at 245.76 MHz that may not be affordable --
  but it is a design change, not a wall.
- `MMCME2_ADV` -> **`PLLE2_BASE`**, which passes cleanly. Appears exactly once,
  in `ad_mmcm_drp.v`, and DRP is dynamic reconfiguration -- likely not needed
  for a fixed-rate receive path at all.

**Correction, same day.** The paragraph that stood here said "nothing found so
far is unbuildable in principle". That was too optimistic, because I searched
only for uppercase primitive names and missed three things a deeper pass found:

- **`MULT_MACRO` has no replacement in yosys.** Verified: the yosys share
  directory in this very container contains no UNIMACRO library and no file
  mentioning `MULT_MACRO` at all. ADI reaches it through `ad_iqcor` and the
  `ad_dds_*` modules, both in the unavoidable generic dependencies. It is a thin
  wrapper over DSP48E1 and can be rewritten, but it is a required patch that my
  primitive table does not list because it is not spelled like a primitive.
- **`BUFR` fails silently rather than loudly.** openXC7's `fasm.cc` hardcodes
  `BUFR_DIVIDE.BYPASS` with no divider path, so a design asking for a divided
  BUFR would place, route and emit an **undivided clock**. That is worse than
  the "no bels" error `BUFIO` gives: a wrong bitstream that builds cleanly.
- **`ad_data_clk.v` needs two substitutions, not one** -- `IBUFG` and
  `IBUFGDS`, in different generate branches -- and the CMOS path uses `IBUFG`
  too, so neither interface mode avoids it.

The honest statement is: **the obstacles are bounded and none is yet proven
fatal, but there are more of them than one grep suggests, and at least one fails
by producing a wrong bitstream rather than by stopping.**

## What this does NOT establish

The primitives were tested **individually**, in minimal designs of a few hundred
LUTs. `axi_ad9361` plus `axi_dmac` plus the AXI interconnect is a different
order of magnitude, and the failure modes that matter at that scale --
timing closure across clock domains, chipdb coverage of the routing actually
needed, nextpnr runtime on a full image -- are entirely untested.

Nor was any ADI file compiled. The next bounded step is to run
`library/axi_ad9361/*.v` plus its `library/common` dependencies through yosys
alone, and see whether it elaborates. That is an afternoon, and it is the
honest next gate.

---

## A fourth obstacle, found by actually running it: `ad_pack.v` hangs yosys

Everything above was found by reading. Running `yosys` over the real tree --
`library/axi_ad9361/*.v` plus `library/common/*.v` plus
`library/xilinx/common/*.v`, with `ad_mul` shimmed onto the open multiplier --
gets to file **34 of about 74** and is then killed.

The file is `library/common/ad_pack.v`. Isolated:

| `library/common/ad_pack.v` alone | result |
|---|---|
| as shipped | **hangs**; killed at 90 s, no output |
| `gcd()` rewritten as a bounded 32-iteration loop with `%` | **hangs** |
| `gcd()` rewritten as a bounded 64-iteration loop, no division | **hangs** |
| `gcd()` rewritten loop-free, `(a<b)?a:b` | **hangs** |
| `localparam STEP = 1;` -- the call removed entirely | **exit 0, 0.01 s CPU, 14 MB peak, zero warnings** |

So it is not the loop, and not the subtractive Euclid, and not division. **It is
the function call itself in that position.** Yosys reports
`wire '\gcd$func$...' is assigned in a block`, which says it is elaborating the
function as hardware rather than folding it to a constant -- and `STEP` feeds
`SH_W`, which sets the width of `idata_dd`, `in_use` and `out_mask`. A width
that never resolves to a number is a vector of unbounded size, and the tool
sits there trying to build it.

Vivado evaluates the same function at elaboration without complaint. This is a
genuine portability gap, it fails as a **hang rather than an error**, and no
rewrite of the function body fixes it.

**The fix for a port is to remove the call, not to improve it**: compute the
GCD in the build script and pass `STEP` in as a parameter. One line at each
instantiation site, and it costs nothing at run time because the value was
always a compile-time constant.

### Where that leaves the count

Four obstacles now, of which only the first was visible from a primitive grep:

1. `IBUFG` / `IBUFGDS` -- unknown to both nextpnr forks. Substitute `IBUFDS`.
2. `BUFIO` no bels; `BUFR` **silently emits an undivided clock**. Substitute `BUFG`.
3. `MULT_MACRO` -- no UNIMACRO library in yosys. **Solved**: `ad_mul_open.v`,
   bit-exact in simulation and structurally identical after synthesis.
4. ~~`ad_pack.v`'s constant function -- hangs yosys~~ **WITHDRAWN**: a yosys
   0.63 defect fixed upstream in v0.67, not an ADI problem. See the correction
   at the end of this file.

And `MMCME2_ADV` remains, failing on a prjxray bit collision, with `PLLE2_BASE`
available.

None of the four is fatal. But the honest shape of this is: **every time this
has been probed more deeply, another one has appeared, and the fourth was
invisible to every method used before running the tool.** The estimate for
"port ADI's receive path to the open flow" should be treated as unbounded below
until the whole tree elaborates once.

---

## The gate is passed: `axi_ad9361` elaborates in yosys

`exit: 0`. Zero errors.

```
read_verilog -lib +/xilinx/cells_sim.v
read_verilog -lib +/xilinx/cells_xtra.v
read_verilog library/axi_ad9361/*.v library/axi_ad9361/xilinx/*.v \
             library/common/*.v library/xilinx/common/*.v
hierarchy -top axi_ad9361 -check
proc; flatten; stat
```

**7 472 cells, 19 621 wires, no errors.** The whole hierarchy resolves --
`axi_ad9361_lvds_if`, `axi_ad9361_rx`, `axi_ad9361_tx`, `axi_ad9361_tdd_if` and
everything under them.

Two source changes were needed, both already documented:

1. `ad_mul_open.v` in place of the UNIMACRO multiplier (`MULT_MACRO_PORT.md`)
2. `localparam STEP = gcd(...)` stubbed in two files -- the constant function
   that hangs the elaborator

Nothing else.

### And the primitive list is far shorter than feared

The flattened design instantiates exactly these Xilinx cells:

| Primitive | count | status |
|---|---|---|
| `OBUFDS` | 8 | untested alone; same family as the proven `IBUFDS` |
| `IBUFDS` | 7 | **proven end to end** |
| `DSP48E1` | 4 | from `ad_mul_open` and `ad_dcfilter` |
| `OBUF` | 2 | trivial |
| `BUFG` | 1 | **proven** |
| `IDELAYCTRL` | 1 | **proven** |
| `IBUFGDS` | **1** | **unknown to both nextpnr forks** |

**`MMCME2_ADV`, `BUFR`, `BUFIO`, `ISERDESE2`, `OSERDESE2` and `IDELAYE2` do not
appear at all** in this parameterisation. Three of the four obstacles catalogued
above are simply not reachable from this configuration of this core.

That leaves **one** problematic primitive, instantiated **once**, with a
one-line substitution (`IBUFDS`) already proven to build to a loadable
bitstream.

### What this does and does not mean

**Does:** the portability question that gated the whole product plan is
answered, and the answer is yes at the elaboration level. ADI's AD9361 core is
not locked to Vivado by its RTL.

**Does not:** elaboration is not synthesis, synthesis is not place-and-route,
and P&R on 7 472 cells plus `axi_dmac` plus the AXI interconnect plus our own
core is where the real risks live -- nextpnr runtime, chipdb routing coverage,
and timing closure on a flow whose timing model has **no sequential component
at all** (see `../TIMING.md`). None of that is touched here.

The estimate for the radio path can now be stated with a floor as well as a
ceiling, which it could not be yesterday.

Log: `results/flat.log`.

---

## Correction: obstacle 4 was never an ADI problem

The section above blamed `ad_pack.v`'s constant function for hanging yosys, and
concluded "the fix for a port is to remove the call". **That diagnosis was
wrong**, and the way it was wrong is worth recording.

The minimal reproduction, with no function anywhere in the file:

```verilog
localparam [31:0] STEP = 2;                 // sized literal   -> HANGS
localparam        STEP = 2;                 // unsized literal -> exit 0
...
for (i = SH_W-STEP; i >= 0; i = i - STEP) ...
```

A **sized** literal is unsigned, which makes the loop variable unsigned, which
makes `i >= 0` tautologically true, and the unroller never terminates. Nothing
to do with `gcd`, with functions, or with loops inside functions. Every
"workaround" tried yesterday -- bounding the loop, removing the division,
removing the loop entirely -- failed because none of them touched the actual
cause, and the one that appeared to work (replacing the call with a literal)
worked only because the literal happened to be unsized.

**It is a yosys defect, fixed upstream before this project ever hit it.**
Commit `38c2806`, "Make sure to apply correct signedness to loop vars", PR
#5887, merged 2026-06-19, released in **v0.67**. This machine was running 0.63.

After `brew upgrade yosys` (0.63 -> 0.67), the same minimal case exits 0, and
**the unmodified ADI tree -- `gcd()` untouched -- elaborates cleanly**:

```
exit: 0    errors: 0    19 621 wires
primitives: 8 OBUFDS, 7 IBUFDS, 4 DSP48E1, 2 OBUF, 1 BUFG, 1 IDELAYCTRL, 1 IBUFGDS
```

Log: `results/elab_unmodified_yosys067.log`.

### What this changes

**The required source changes to ADI's tree drop from two to one.** Only
`ad_mul_open.v` remains, because yosys genuinely ships no UNIMACRO library.
`ad_pack.v` needs nothing.

And the general lesson, which cost a full cycle: **before attributing a tool
failure to the code being compiled, check the tool's version against upstream.**
Four "obstacles" were catalogued here across several cycles; this one was an
artefact of a stale binary, and the effort spent designing workarounds for it
was wasted on a bug someone else had already fixed.

---

## Synthesised, with numbers

`synth_xilinx -family xc7 -top axi_ad9361 -flatten`, yosys 0.67, one patch
(`ad_mul_open`), `gcd()` untouched. **exit 0, zero errors.**

| | LUT (LUT1-6) | FF | CARRY4 | SRL16E | DSP48E1 | BRAM |
|---|---|---|---|---|---|---|
| `axi_ad9361` | **7 447** | 11 005 | 1 378 | 545 | 12 | **0** |

Against an XC7Z020 (53 200 LUT6, 106 400 FF, 220 DSP48E1, 140 BRAM36):

| | LUT | FF | DSP |
|---|---|---|---|
| `axi_ad9361` | 7 447 (**14.0%**) | 11 005 (10.3%) | 12 |
| our 63-tap correlator | 9 534 (**17.9%**) | 1 200 (1.1%) | **0** |
| both | 16 981 (**31.9%**) | 12 205 (11.5%) | 12 |
| headroom | 36 219 LUT | 94 195 FF | 208 DSP |

**The two fit together with room to spare.** That is the number this line of work
existed to produce, and it did not exist yesterday.

### Four things to say before anyone else does

- **Our core is bigger than ADI's whole receive path** -- 9 534 LUT against
  7 447. The multiplier-free 63-tap tree is not a small thing; it costs about
  a fifth of the device on its own, and it buys zero DSP48 in exchange. That is
  the trade, stated plainly.
- **This does not include `axi_dmac`, the AXI interconnect, `util_cpack` or the
  PS7 glue.** A real image needs all of them. The number above is a floor, not
  an estimate of the finished thing.
- **5 802 `INV` cells** are in that count. Vivado folds inversions into LUT
  inputs; yosys emits them explicitly and the mapper does not always absorb
  them. The true LUT figure on a vendor flow would very likely be lower, so
  this is conservative in the direction that matters.
- **Synthesis is not place-and-route.** Nothing here says nextpnr can route
  17 000 LUTs of AXI-heavy logic on this chipdb, in what runtime, or at what
  clock. On a flow whose timing model has no sequential component at all
  (`../TIMING.md`), the only trustworthy answer will be a measured one.

Log: `results/synth_axi_ad9361.log`.

---

## The obstacle list is now empty

Two findings close it.

### Distributed RAM: the known P&R killer does not apply

The failure that stopped other large open-flow ports is strict legalisation of
distributed RAM (`DPR0`) -- not design size. Measured across three synthesis
configurations:

| | LUT | SRL16E | RAM32M / RAM64M / RAM32X1D | FF |
|---|---|---|---|---|
| default | 7 447 | 545 | **0 / 0 / 0** | 11 005 |
| `-nosrl` | 7 859 | **0** | 0 / 0 / 0 | 13 248 |
| `-nosrl -nolutram` | 7 859 | 0 | 0 / 0 / 0 | 13 248 |

**`axi_ad9361` instantiates no distributed RAM at all**, in any configuration.
The `DPR0` legalisation path is never entered. And if the 545 `SRL16E` were ever
to cause trouble, they cost **+412 LUT and +2 243 FF** to remove entirely --
cheap insurance, available on a flag.

For scale, the size worry was misplaced anyway: the Wally project routed
**3 006 731 wires** on an XC7K325T through this flow, orders of magnitude past
anything here.

### The last unsupported primitive is gone

`IBUFGDS` appeared once, in `ad_data_clk.v:66`, with `IBUFG` in the
single-ended branch of the same generate. **Both are followed immediately by a
`BUFG`**, which is what provides global clock routing -- so the `G` variants are
redundant at that call site and a plain differential buffer is functionally
identical.

After substituting `IBUFDS` for `IBUFGDS` and `IBUF` for `IBUFG` in
`ad_data_clk.v` and `ad_serdes_clk.v`:

```
545 SRL16E, 246 IBUF, 208 OBUF, 12 DSP48E1, 8 OBUFDS, 4 BUFG, 1 IBUFDS, 1 IDELAYCTRL
primitives still unsupported by nextpnr: NONE
LUT 7 447, FF 11 005 -- unchanged; the substitution is free
```

### Where this leaves the port

**Two patches, both verified, and no known obstacle remains:**

1. `ad_mul_open.v` replacing the UNIMACRO multiplier -- bit-exact in
   simulation, structurally identical after synthesis
2. `adi-openxc7.patch` -- four primitive substitutions in two clock files

`gcd()` needs nothing; that was a yosys 0.63 defect, fixed in 0.67.

What remains untested is place-and-route: nextpnr runtime on ~17 000 LUTs of
AXI-heavy logic, prjxray routing coverage at that scale, and timing closure on a
flow with no sequential timing model. Those are real and they are next. But the
question "can this design be expressed at all without Vivado" is now closed, and
the answer is yes.

---

## The full image, and a correction to yesterday

Yesterday this file concluded that the `DPR0` distributed-RAM legalisation
failure "does not apply to this design". **That was true of `axi_ad9361` alone
and false of the image that would actually be built.** `axi_dmac` brings
distributed RAM in:

| `axi_dmac` | LUT | FF | BRAM36 | distributed RAM |
|---|---|---|---|---|
| default | 597 | 874 | 1 | **10 x RAM32M** |
| `-nolutram` | 725 | 960 | 1 | **0** |

Ten `RAM32M` cells is exactly the class that stopped other large open-flow
ports. The mitigation is **+128 LUT and +86 FF** -- 21% more logic in a block
that is 3% of the image -- and it removes the hazard entirely.

The lesson is the same one that keeps recurring here: a property measured on one
block is not a property of the system. It took synthesising the second block to
find it.

## The complete resource picture

Every number below is measured, not estimated. `axi_dmac` in its safe
(`-nolutram`) configuration.

| block | LUT | FF | DSP | BRAM36 | distRAM |
|---|---|---|---|---|---|
| `axi_ad9361`, patched | 7 447 | 11 005 | 12 | 0 | 0 |
| `axi_dmac`, `-nolutram` | 725 | 960 | 0 | 1 | 0 |
| our 63-tap correlator | 9 534 | 1 200 | 0 | 0 | 0 |
| **total** | **17 706** | **13 165** | **12** | **1** | **0** |
| **of XC7Z020** | **33.3%** | **12.4%** | **5%** | **0.7%** | -- |
| headroom | 35 494 | 93 235 | 208 | 139 | -- |

**A third of the device, with no distributed RAM anywhere.** The one known
place-and-route killer is designed out rather than hoped past.

Still not counted: the AXI interconnect and the PS7 glue. Both are small
relative to these three, but "small" is an estimate and everything else here is
a measurement, so it is named as an estimate.

Logs: `results/synth_axi_ad9361_patched.log`, `results/synth_axi_dmac.log`.

---

## Place-and-route attempted: three findings, and a correction to my own numbers

The toolchain is now local (yosys 0.67 + nextpnr-xilinx from nix + the saved
chipdb; see `../ATSPEED.md`). Attempting to place `axi_ad9361` produced more
than a result -- it produced three things nothing before it had found.

### 1. The default parameterisation is not a valid 7-series configuration

`axi_ad9361` defaults to `FPGA_TECHNOLOGY = 0`. Seven-series is `1`. At `0` the
delay elements are not instantiated but their controller still is, and openXC7's
design-rule check catches it exactly:

```
ERROR: Found IDELAYCTRL but no I/ODELAYs in group dev_if_delay_group
```

That check is correct and it is a point in the tool's favour -- an orphaned
`IDELAYCTRL` is useless silicon, and a flow that silently accepted it would be
worse.

**This invalidates the resource numbers recorded earlier in this file.** They
were synthesised at `FPGA_TECHNOLOGY = 0`. With the correct family:

| `axi_ad9361` | LUT | FF | CARRY4 | DSP48E1 | IDELAYE2 |
|---|---|---|---|---|---|
| as previously recorded (`FPGA_TECHNOLOGY=0`) | 7 447 | 11 005 | 1 378 | **12** | 0 |
| correct 7-series, LVDS | ~10 162 | 14 097 | 1 522 | **28** | 7 |
| correct 7-series, CMOS (what Pluto uses) | ~10 306 | 14 109 | 1 522 | **28** | 13 |

*(the LUT figures include a small harness; the DSP and IDELAY counts are the
design's own.)*

**The DSP count more than doubles, 12 to 28.** Still 13% of the 220 available,
so the conclusion that everything fits is unchanged -- but the number I
published was for a configuration nobody would build.

### 2. openXC7 rejects an explicitly instantiated input buffer on IDELAYE2

```
ERROR: IDELAYE2 ... has IDATAIN input connected to illegal cell type IBUFDS
ERROR: IDELAYE2 ... has IDATAIN input connected to illegal cell type IBUF
```

Both modes, LVDS and CMOS. ADI instantiates the buffer explicitly in
`ad_data_in.v:168-176`; openXC7's packer expects the IOB path to be implicit and
packs it itself.

This is verifiable against our own earlier work: `primtest/prim_idelay.v`, which
drives `.IDATAIN(port)` directly and lets the tool insert the buffer, **builds
all the way to a loadable bitstream**. The same primitive fails here purely
because of how it is reached.

That makes it a fourth patch for the port, and unlike the others it was
invisible to synthesis -- only place-and-route found it.

### 3. A pin-less harness cannot test a delay path at all

Removing the explicit buffer moved the error rather than fixing it:

```
ERROR: IDELAYE2 ... has IDATAIN input connected to illegal cell type FDSE
```

`FDSE` is a flip-flop -- **the LFSR in my own harness**. `IDELAYE2.IDATAIN` must
come from a real IOB, and a harness built to need no package pins can never
supply one. The technique that made the 63-tap scaling test possible is
structurally unable to test this core's input path.

The correct harness promotes the AD9361 bus to real top-level ports -- 14 IBUF,
16 OBUF and clocks, about 35 pins, which clg400 can supply -- and keeps only the
AXI and control side internal. That is the next attempt, and it is a different
piece of work from what was tried here.

### Where this leaves the estimate

Elaboration: **done**. Synthesis: **done, with corrected numbers**. Place and
route: **not yet, and now for a specific and understood reason** rather than an
unknown one. The obstacle list, which was empty at the end of the last cycle, has
one new entry that only P&R could have found -- which is the argument for doing
P&R early rather than treating synthesis as the finish line.

---

## `axi_ad9361` places and routes on an XC7Z020

With a harness that gives the AD9361 CMOS bus **30 real package pins** (banks 34
and 35, from `package_pins.csv`) and drives everything else from an internal
LFSR, `FPGA_TECHNOLOGY=1`, `CMOS_OR_LVDS_N=1`:

```
iter=4   wires = 701 422   overused = 0   overuse = 0   archfail = 0
Max frequency 'FCLKCLK[0]' :  48.25 MHz  (PASS at 30.72 MHz)
Max frequency 'o_l_clk'    : 370.92 MHz  (PASS at 12.00 MHz)
SLICE_LUTX 25 747/106 400 (24%)    SLICE_FFX 14 109/106 400 (13%)
CARRY4      1 524/13 300  (11%)    RAMB36/18  0 / 0
wall clock: 263 s        FASM written: 20 MB, 602 570 lines
```

**The routing converged completely** -- zero overuse, zero architecture
failures, in four iterations. Both clock domains meet their constraints. A
20 MB FASM was produced.

### One more tie-off, the same family as before

Getting here needed a fifth patch, and it is the pattern already documented in
`RESULTS.md`: nextpnr cannot route a constant to a dedicated cascade wire.
`ad_dcfilter.v` ties six of them on its DSP48E1 --
`MULTSIGNIN`, `CARRYIN`, `CARRYCASCIN`, `ACIN`, `BCIN`, `PCIN`:

```
ERROR: Unrouteable $PACKER_GND_NET sink u_dut...i_dsp48e1.CARRYCASCIN
```

Removing the tie-offs -- leaving the pins unconnected, which is what the tool
expects -- fixes it. Same fix as `DDLY` / `SHIFTIN1` / `CLKDIVP` on ISERDESE2.

### What actually stops a bitstream now

```
Info: Running post-routing legalisation...
libc++abi: terminating due to uncaught exception of type
  nextpnr_xilinx::assertion_failure:
  Assertion failure: is_string (common/nextpnr.h:365)
```

**A nextpnr internal assertion, after routing succeeded.** Not a design fault,
not a routing failure, not a resource limit -- an internal property read as a
string when it is not one. It is reproducible, it has a source line, and it is
the only thing between this design and a loadable bitstream.

That makes it the second genuine upstream defect this project has found, after
the `BUFR_DIVIDE.BYPASS` silent-wrong-clock issue. Both are worth filing.

### The honest state of the port

| stage | status |
|---|---|
| elaboration | **done** |
| synthesis | **done**, numbers corrected for `FPGA_TECHNOLOGY=1` |
| placement | **done**, 24% of the device |
| routing | **done**, 701 422 wires, zero overuse |
| timing | **passes** both domains, 48.25 and 370.92 MHz reported |
| FASM | **written**, 20 MB |
| bitstream | **blocked** on a nextpnr assertion in post-routing legalisation |

Five patches to ADI's tree, all small, all documented: the multiplier, four
primitive substitutions in two clock files, and six DSP cascade tie-offs.

Harness and constraints: `ps7_ad9361_pins.v`, `ps7_ad9361_pins.xdc`.
Log: `results/pnr_axi_ad9361.log`.

---

## The assertion, diagnosed but not yet defeated

`common/nextpnr.h:365` is `Property::as_string()`, which asserts `is_string`.
The message "Running post-routing legalisation..." comes from
`xilinx/arch_place.cc:922`, so the offending read is in that function or
something it calls.

nextpnr-xilinx was rebuilt from source at revision `96bb068` -- the same
revision as the working nix binary, because a build from current master fails
immediately with *"The internal IDs of nextpnr are inconsistent with the
supplied chip database"*: the chipdb is tied to the constid table of the
nextpnr that generated it, and it fails loudly rather than silently, which is
the right behaviour.

Three unrelated breakages had to be fixed just to compile that revision today
(Boost's removed `system` library, `CMAKE_CXX_STANDARD 11` against Eigen 5's
C++14 minimum, and `std::random_shuffle` removed in C++17). All three are
one-line and are written up in `../UPSTREAM_BUGS.md`.

**The obvious fix did not work.** Applying the codebase's own documented
tolerant read -- `Property::str` instead of `as_string()`, exactly as
`fasm.cc`'s `dsp_str` lambda does -- to both `X_ORIG_PORT_*` sites inside the
legalisation function leaves the crash exactly where it was. So the read is in
a callee, not in the function itself. That is a useful narrowing and it is in
the bug report, but it is not a fix.

The run with the patched binary reproduces everything else:

```
iter=5   wires = 692 791   overused = 0   archfail = 0
'o_l_clk'    : 349.04 MHz (PASS at 12.00 MHz)
'FCLKCLK[0]' :  62.46 MHz (PASS at 30.72 MHz)
FASM written: 19 MB, 594 173 lines, last line intact
then: assertion failure at nextpnr.h:365
```

**A 19 MB FASM exists and its last line is a complete feature.** Whether it is
semantically complete -- whether post-routing legalisation would have added or
corrected anything -- is unknown, and the tooling to turn it into a bitstream
(`fasm2frames`, `xc7frames2bit`) is not currently installed, having lived in the
container image that was deleted to free disk. So the honest status is: **a
FASM of unverified completeness, and no bitstream.**

Log: `results/pnr_axi_ad9361_patched.log`.

---

## nextpnr completes: `exit 0`

The assertion is defeated. A backtrace from an instrumented
`Property::as_string()` named the site exactly, and it was **not** where the
printed message pointed:

```
=== as_string() on a NUMERIC Property, str="000000000000000000000000000000000000000000000000" ===
  Property::as_string()  <-  FasmBackend::write_dsp_cell  <-  write_fasm  <-  writeFasm
```

`write_dsp_cell`, on a 48-bit all-zero DSP48E1 parameter. The last line printed
before the abort is `Running post-routing legalisation...`, which is why an
earlier cycle patched that pass and changed nothing. **Instrumenting beat
guessing, and it took one run.**

Replacing the nine parameter reads and one attribute read in `write_dsp_cell`
with a direct `Property::str` -- the tolerant pattern upstream added to this
same function later -- gives:

```
exit: 0        elapsed 291 s
iter=5   wires = 692 791   overused = 0   archfail = 0
'o_l_clk'    : 349.04 MHz  (PASS at 12.00 MHz)
'FCLKCLK[0]' :  62.46 MHz  (PASS at 30.72 MHz)
FASM: 19 MB
```

**ADI's AD9361 receive core now goes end to end through yosys and
nextpnr-xilinx, with no errors and no aborts.**

Patch: `../nextpnr-dsp-fasm-fix.patch`. Log: `results/pnr_axi_ad9361_exit0.log`.

### What is still missing for a loadable bitstream

`fasm2frames` and `xc7frames2bit`, which turn the FASM into a `.bit`. They lived
in the container image deleted to free disk, and nixpkgs has no `prjxray` for
aarch64-darwin. The prjxray **database** is present (it came with nextpnr), so
the remaining work is either building those two tools for this platform or
writing the conversion against the database directly -- `bitcanon.py` already
documents the `.bit` container format from the other direction.

So: **placement, routing, timing and FASM all complete and clean; one file
format conversion short of a bitstream.**

---

## Half of the bitstream conversion is done, and the other half is named

`fasm2frames_open.py` assembles nextpnr's FASM into configuration frames using
the prjxray **Python** library, which installs on aarch64-darwin even though the
C++ `prjxray` package does not. On the `axi_ad9361` FASM:

```
frames assembled : 5 936
words per frame  : 101
address range    : 0x00000900 .. 0x0042241D
non-zero words   : 288 992
```

So the FASM is real, and every feature in it resolves against the database.

*(A note on a number I nearly published: `set_feature_callback` fires on **every**
feature, not only unknown ones -- `add_fasm_line` calls it unconditionally.
Counting its invocations and labelling the result "missing" reported 557 061
unresolved features in a design that has 594 173 FASM lines, which would have
meant the assembly was empty. It is not; that figure is the total processed.
Genuinely unresolved features come back through `parse_fasm_filename`'s own
list.)*

### Why the second half was not simply written

A working xc7z020 bitstream -- taken from `ps7_corr.swab.bin`, produced by the
real `xc7frames2bit` -- has this shape:

```
sync 0xAA995566 at offset 48
Type-1 setup packets: IDCODE 0x03727093, FAR, COR, CTL ...
FDRI Type-2 at byte 232: 1 010 808 words = exactly 10 008 frames of 101
explicit CRC register writes: 0
2 096 bytes of closing commands
```

Two useful facts fall out: **no CRC is written**, so nothing has to be
recomputed; and the payload is one contiguous FDRI packet, so substituting
frame data is a byte-range replacement rather than a packet-stream synthesis.

But **the bitstream holds 10 008 frames and the database knows 7 802.** The
2 206 extra are padding the 7-series configuration stream carries at row and
block boundaries, which are not database entries. Address-sorted order is
therefore *not* the payload order, and a wrong mapping yields a bitstream that
loads and then misbehaves -- strictly worse than no bitstream, and exactly the
failure mode this project has spent the whole session trying not to produce.

**The derivation is empirical and self-validating**: assemble the FASM of a
design whose `.bit` is already known good, then locate each frame's 101 words
inside that template's FDRI payload. Every frame must be found exactly once; if
any is not, the mapping is wrong and says so. That is the next step, and it
needs one nextpnr run of a small design to produce the matching FASM.
