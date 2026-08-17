# Defects found in openXC7

These were found while porting Analog Devices' AD9361 receive core to the
vendor-free flow. All are in the tool, not in ADI's HDL, and are written up in
the form a maintainer would want.

**One of them has not been reproduced here.** Item 1 is a source reading whose
consequence was never built or measured; it says so where it appears, and the
evidence table at the end gives the status of every item. Read that before
filing anything.

---

## 1. `BUFR` with a divider appears to emit an undivided clock

**This one is a source reading, not an observation. Read the evidence note
before sending it.**

**Severity if confirmed: high.** It would produce a *wrong bitstream that builds
cleanly* -- no error, no warning, and no way to notice except by measuring the
hardware.

`xilinx/fasm.cc` hardcodes `BUFR_Y*.BUFR_DIVIDE.BYPASS` and emits no divider
setting at all. A design instantiating

```verilog
BUFR #(.BUFR_DIVIDE("2")) u (.I(clk_in), .O(clk_div2), .CE(1'b1), .CLR(1'b0));
```

would therefore place, route and produce a bitstream in which `clk_div2` runs at
the **input frequency**, not half of it, with every downstream register sampling
at twice the intended rate.

**What was actually done here, and what was not.** The hardcoded `BYPASS` was
read in the source. The consequence above is inferred from it and has **not been
built or measured**. This project's divided clocks all came from a PS clock
divider or a fabric divide-by-two, never from `BUFR_DIVIDE`, so the case was
never exercised even by accident -- `MULT_MACRO_PORT.md` says of this and the
neighbouring obstacles that "none has been tried in anger", and that is
accurate.

The distinction matters precisely because of the severity claim: a defect whose
whole point is that *only hardware measurement reveals it* cannot be reported as
observed by someone who did not measure it. Sending it as an observation invites
a maintainer to check, find no run behind it, and discount the rest of this file
-- which includes a defect that is properly evidenced.

**What would settle it:** build the four-line design above, load it, and compare
the frequency at a fabric counter against the input. That is a one-cycle
experiment on a working board.

**Why it matters here:** ADI's `ad_data_clk.v` and `ad_serdes_clk.v` use `BUFR`
in exactly this way for the AD9361 bus clock. A user who did not know would get
a board that appears to build and then misbehaves in a way that looks like a
hardware fault.

**Suggested minimum fix, if confirmed:** reject a non-`BYPASS` `BUFR_DIVIDE`
with an error until the divider bits are implemented. Silence is the worst
option available.

---

## 2. `is_string` assertion writing the FASM for a DSP48E1 -- FIXED, patch below

**Severity: medium.** It aborts after all the work is done -- placement, routing
and timing all complete -- so it costs the entire run.

```
libc++abi: terminating due to uncaught exception of type
  nextpnr_xilinx::assertion_failure: Assertion failure: is_string
  (common/nextpnr.h:365)
```

**The location matters and an earlier version of this file got it wrong.** The
last line printed before the abort is `Running post-routing legalisation...`
(`xilinx/arch_place.cc:922`), which made the legalisation pass the obvious
suspect. It is not. Instrumenting `Property::as_string()` to print a backtrace
gives:

```
=== as_string() on a NUMERIC Property, str="000000000000000000000000000000000000000000000000" ===
  Property::as_string()
  <- FasmBackend::write_dsp_cell(CellInfo*)
  <- FasmBackend::write_fasm()
  <- Arch::writeFasm()
  <- customBitstream()
```

It is **`write_dsp_cell`**, and the value is a 48-bit all-zero parameter --
`PATTERN` or `MASK` on a DSP48E1. yosys stores all-binary parameter values as
*numeric* Properties; `str_or_default()` and `as_string()` assert on those.

Patching the two `X_ORIG_PORT_*` reads inside the legalisation function, as an
earlier attempt did, changes nothing -- which is worth knowing, because the
printed message points at the wrong pass.

**Fix, verified.** `write_dsp_cell` at revision `96bb068` reads nine parameters
and one attribute with `str_or_default`. Replacing them with a direct
`Property::str` read -- exactly the `dsp_str` lambda upstream added to this
function later, and for this reason -- makes the run complete:

```
exit: 0    692 791 wires    overused 0    archfail 0
'o_l_clk'    349.04 MHz (PASS at 12.00 MHz)
'FCLKCLK[0]'  62.46 MHz (PASS at 30.72 MHz)
FASM: 19 MB
```

So on a current openXC7 this may already be fixed; on `96bb068`, which is what
nixpkgs ships for aarch64-darwin, it is not. The useful report is therefore:
**backport the `dsp_str` tolerant read**, and separately consider making
`as_string()` return `str` rather than assert, since every call site that has
hit this has wanted the characters either way.

## Three smaller things worth reporting together

Not bugs exactly, but each cost time and each is cheap to fix or document.
Unlike item 1, each of these was hit during an actual build -- the error strings
below are quoted from runs, not predicted:

- **`IBUFG` / `IBUFGDS` are unknown identifiers**, not merely unsupported: the
  strings appear nowhere in either fork. A design using them fails at placement
  with "no Bels remaining", which reads as a resource problem rather than a
  missing feature. `IBUFDS` works and is a drop-in where a `BUFG` follows.
- **Constants cannot be routed to dedicated site wires.** `DDLY`, `SHIFTIN1`,
  `SHIFTIN2`, `CLKDIVP` on `ISERDESE2`; `CARRYCASCIN`, `MULTSIGNIN`, `CARRYIN`,
  `ACIN`, `BCIN`, `PCIN` on `DSP48E1`. Vivado tolerates the tie-off; here the
  pin must be left unconnected. The error (`Unrouteable $PACKER_GND_NET sink`)
  does not say so.
- **An explicitly instantiated input buffer feeding `IDELAYE2.IDATAIN` is
  rejected** ("illegal cell type IBUF/IBUFDS") although driving `IDATAIN`
  straight from a port -- letting the tool insert the buffer -- works and builds
  to a loadable bitstream. Both forms are legal in Vivado.

## Build notes for anyone compiling `96bb068` today

Three unrelated breakages on a current toolchain, all one-line:

- `set(boost_libs ... system)` -- Boost dropped the `system` library (header-only
  since 1.69). Upstream `stable-backports` already removes it.
- `set(CMAKE_CXX_STANDARD 11)` -- Eigen 5 requires >= 14.
- `std::random_shuffle` in `common/placer_heap.cc` -- removed in C++17. An
  explicit Fisher-Yates over the same `ctx->rng` preserves the sequence.


---

## Evidence, per item

Added 2026-08-04, after an audit that asked of every claim in this file: which
run produced it?

| item | evidence | status |
|---|---|---|
| 1. `BUFR` divider ignored | source read of `xilinx/fasm.cc` | **inference, never built or measured** |
| 2. `is_string` assertion on DSP48E1 | crash trace, instrumented backtrace, fix, and a completing run with numbers | observed |
| `IBUFG`/`IBUFGDS` unknown | placement failure during a real build | observed |
| constants to dedicated site wires | quoted error from a real build | observed |
| buffer feeding `IDELAYE2.IDATAIN` | quoted error from a real build | observed |

Item 1 is the only one resting on reading rather than running, and it is the one
whose severity claim depends on hardware measurement. That combination is why it
now says so on its face.

The audit itself came out of a related finding the day before: `PRIOR_ART.md`
claimed the flow had been "shown to place and route `IBUFDS`, `PLLE2`,
`OSERDESE2` and `ISERDESE2`", when `PLLE2`, `OSERDESE2` and `ISERDESE2` appear
nowhere else in this project's records. Claims written from memory of what a
flow touched, rather than from what it completed, are the failure mode both
documents shared.
