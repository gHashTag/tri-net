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

## 2. `is_string` assertion in post-routing legalisation

**Severity: medium.** It aborts after all the work is done -- placement,
routing and timing all complete successfully -- so it costs the whole run.

```
Info: Running post-routing legalisation...
libc++abi: terminating due to uncaught exception of type
  nextpnr_xilinx::assertion_failure: Assertion failure: is_string
  (common/nextpnr.h:365)
```

`common/nextpnr.h:365` is `Property::as_string()`, which asserts `is_string`.
Something reached from `xilinx/arch_place.cc:922` (`log_info("Running
post-routing legalisation...")`) reads a Property as a string when yosys stored
it as numeric. Yosys emits numeric Properties for attribute values that look
like bit-strings, so an attribute whose value happens to be e.g. `"0"` or `"10"`
takes the numeric path.

**The codebase already knows this failure mode and documents the remedy**, in
`xilinx/fasm.cc` (the `dsp_str` lambda):

> *"SVS/yosys store all-binary parameter values ... as numeric Properties, on
> which `str_or_default()`/`as_string()` assert (`is_string == false`).
> `Property::str` holds the literal for string params AND the `[01xz]`
> bit-string for numeric ones (exactly what `as_string()` would have returned),
> so reading it directly is bit-for-bit equivalent but never aborts."*

**What was tried, and what it tells you.** Applying that same tolerant read to
the two `X_ORIG_PORT_*` sites inside the legalisation function
(`arch_place.cc:972,974` at revision `96bb068`) does **not** fix it -- the crash
persists at the same line. So the offending read is in a function *called from*
post-routing legalisation, not in the function itself. That narrows it usefully
and is worth stating in the report.

**Reproduction.** ADI `analogdevicesinc/hdl` master, `axi_ad9361` with
`FPGA_TECHNOLOGY=1`, `CMOS_OR_LVDS_N=1`, five small patches (documented in
`primtest/RESULTS_AD9361.md`), yosys 0.67, nextpnr-xilinx `96bb068`,
xc7z020clg400-1. Routing converges -- 692 791 wires, overuse 0, archfail 0,
timing passing on both clock domains -- and a 19 MB FASM is written. Then it
aborts.

**Suggested fix:** replace `as_string()` with a direct `.str` read on every
attribute access reachable from post-routing legalisation, exactly as `dsp_str`
already does, or make `as_string()` return `str` instead of asserting when the
Property is numeric.

---

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
