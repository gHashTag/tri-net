# Two defects found in openXC7, with reproductions

Both were found while porting Analog Devices' AD9361 receive core to the
vendor-free flow. Both are in the tool, not in ADI's HDL. They are written up
here in the form a maintainer would want, so they can be filed as-is.

---

## 1. `BUFR` with a divider silently emits an undivided clock

**Severity: high.** This produces a *wrong bitstream that builds cleanly*. There
is no error, no warning, and no way to notice except by measuring the hardware.

`xilinx/fasm.cc` hardcodes `BUFR_Y*.BUFR_DIVIDE.BYPASS` and emits no divider
setting at all. A design instantiating

```verilog
BUFR #(.BUFR_DIVIDE("2")) u (.I(clk_in), .O(clk_div2), .CE(1'b1), .CLR(1'b0));
```

places, routes and produces a bitstream in which `clk_div2` runs at the **input
frequency**, not half of it. Every downstream register then samples at twice the
intended rate.

**Why it matters here:** ADI's `ad_data_clk.v` and `ad_serdes_clk.v` use `BUFR`
in exactly this way for the AD9361 bus clock. A user who did not know would get
a board that appears to build and then misbehaves in a way that looks like a
hardware fault.

**Suggested minimum fix:** reject a non-`BYPASS` `BUFR_DIVIDE` with an error
until the divider bits are implemented. Silence is the worst option available.

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

Not bugs exactly, but each cost time and each is cheap to fix or document:

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
