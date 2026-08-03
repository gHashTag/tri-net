# Timing, constrained at last

Every Fmax this project ever quoted was produced with no timing constraint:
`create_clock` appeared nowhere, `build/ps7_corr.xdc` and `build/ps7_probe.xdc`
were zero bytes, and nextpnr was therefore aiming at its own 12.00 MHz default.
`ps7_corr_timed.xdc` fixes that. Measured 2026-08-03, `--seed 1`:

```
Info: Max frequency for clock 'FCLKCLK[0]': 115.00 MHz (PASS at 30.72 MHz)
Info: 3.1 ns logic, 5.6 ns routing
Info: 	SLICE_LUTX:   910/106400
Info: 	    RAMB18E1:     0/280
Info: 	     (DSP48E1:     0)
Info:            202x FDRE
```

Full log: `results/ps7_corr_timed_pnr.log`.

## What is now true, and what was overstated before

**The 115.00 MHz figure is real.** It is nextpnr's post-route static timing
estimate for `ps7_corr`, and it reproduces. Earlier criticism in this repo said
the number "appears nowhere in the log" -- that was true of
`build/REPRODUCTION.log`, which covers `ps7_tern` and `ps7_probe` only, and
wrong about the correlator.

**What was genuinely wrong was the absence of a constraint.** An unconstrained
nextpnr run reports the longest path it happened to leave, against a 12 MHz
target it was never asked to beat. The sister design's spread of 186 -> 308 MHz
across unseeded runs is what that looks like. With `create_clock` at 30.72 MHz
the tool is now being asked a real question and answers it: **PASS, with 3.7x
margin.**

**910 LUT / 202 FF / 0 DSP / 0 BRAM now has a committed log behind it.** Those
figures previously existed only in a commit message.

## Caveats a reviewer will raise, stated first

- **nextpnr's LUT denominator is 106400**, which counts LUT5 halves. Against the
  industry-standard 53200 LUT6 basis the figure is ~910/53200 = 1.7%, not 0.86%.
  Never mix the two bases in one sentence.
- **`set_false_path` is not supported** (one of only two commands the parser knows) — `Info: ignoring unsupported XDC command
  'set_false_path' (on line 25)`. The EMIO inputs crossing into the fabric are
  therefore still being timed as if they were synchronous. They are not; two-flop
  synchronisers exist precisely to make them harmless. The reported Fmax is
  consequently pessimistic, not optimistic — but it is also not the number a
  Vivado-based reviewer would produce.
- **This is nextpnr's own STA, not Vivado's.** It is a legitimate constrained
  result from the flow that actually builds the artefact, and it is not
  interchangeable with a vendor timing signoff.
- **Part/speed grade:** built as `xc7z020clg400-1`. Documentation elsewhere in
  this repo says `XC7Z020-2CLG400I`. Different bins; fix one or the other before
  quoting timing to anyone.

## Where the critical path is

```
carry chain: maccmap CARRY4 slices -> u_corr.corr[19]  (accumulator MSB)
8.7 ns total: 3.1 ns logic, 5.6 ns routing
```

Routing-dominated by nearly 2:1, which is what a small scattered design looks
like. If the 8-tap core ever needs to go faster, floorplanning will buy more
than arithmetic restructuring.

---

## 63 taps: the structure matters more than the arithmetic

The 8-tap core is a primitive. 63 is the length the DSSS link actually
despreads with, so it is the number that decides whether any of this scales.
Both variants already in the repository were built and constrained at 30.72 MHz,
`--seed 1`:

| 63-tap variant | Fmax | LUT | CARRY4 | FF | verdict |
|---|---|---|---|---|---|
| `tern_corr_pn_stream` (linear) | **5.26 MHz** | -- | 751 | 1200 | **FAIL at 30.72 MHz** |
| `tern_corr_pn_tree` (adder tree) | **58.36 MHz** | 9534 | 386 | 1200 | **PASS, 1.9x margin** |

An 11x difference from changing nothing but the shape of the summation. The
linear despreader ripples a carry through 63 additions and cannot run at the
radio rate on this part; the tree can, comfortably.

Two things follow that are worth saying out loud:

- **The "ternary correlators do not scale" worry is answered for N=63, and
  answered by structure, not by arithmetic.** Anyone quoting the linear variant's
  timing as evidence against the approach is quoting the wrong design.
- **9534 LUT / 63 taps = 151.3 LUT per tap.** That figure has circulated in this
  project's own documents with no log behind it. It is now measured, and it is
  correct. Extrapolating it honestly: a 1023-tap despreader would need roughly
  154 000 LUT, which is about 1.5x this device on nextpnr's 106400 basis and
  ~2.9x on the standard 53200 LUT6 basis. **At radar code lengths this structure
  does not fit, and that remains true.** 63 fits; 1023 does not.

Critical path for the tree variant: 4.3 ns logic, 12.8 ns routing. Routing
dominates 3:1 -- even more lopsided than the 8-tap core. Floorplanning, not
arithmetic, is where any further speed lives.

## Proven in silicon, 63 taps

`ps7_pn_tree.swab.bin` was loaded into the PL and fed the same 256-sample
over-the-air capture, with the PN taps loaded over EMIO:

```
anchor: 0x47C0 (expected 0x47C0)
ingest counter 0 -> 1 (delta 1)
=== VERDICT: 256 of 256 bit-exact against the software reference ===
The 63-tap PN despreader ran in the fabric on real over-the-air samples.
EXIT_CODE=0
```

Code: the project's own m-sequence from `tern_pn_lfsr.v` -- 6-bit Fibonacci
LFSR, x^6 + x^5 + 1, seed 0x3F, taps
`++++++-----+----++---+-+--++++-+---+++--+--+-++-+++-++--++-+-+-`.
Reference: `pn_reference.py`. Harness: `pn_stream.c`. Log:
`results/pn63_success.log`.

This is the 8-tap result at eight times the length and a wider accumulator, and
it came out first try once the instrument was right -- which is itself evidence
that the four defects found on the 8-tap run were harness defects and not design
defects.

---

## Correction 2026-08-03: the tool has no register timing model

This file said the open flow's timing model is "conservative by roughly 1.5x".
That framing is wrong and the correction matters, because it was repeated into a
customer-facing document.

Read from the source inside the very container these builds run in,
`/nextpnr-xilinx/xilinx/arch.cc`:

```
1297    info.setup    = getDelayFromNS(0.1);
1298    info.hold     = getDelayFromNS(0.1);
1299    info.clockToQ = getDelayFromNS(0.1);
```

`getPortClockingInfo` returns those constants **unconditionally, for every
sequential cell in every design**. There is no per-cell sequential timing model
at all. A real 7-series FD contributes something closer to 0.4-0.6 ns of setup
plus clock-to-Q combined; nextpnr books 0.2 ns and moves on.

So the reported Fmax is a routing-and-logic estimate with a placeholder where
the flip-flops should be. **That it landed below measured silicon rather than
above is luck, not calibration**, and the "1.5x conservative" figure is a
property of one design on one seed, not a factor anyone should apply elsewhere.

Two consequences:

- **Quote the measured number, not the tool's.** 83.3 MHz clean and 90.9 MHz
  onset are silicon; 58.26 MHz is an estimate whose error bars are unknown in
  both directions.
- **Timing-driven placement is running on fictional register timing for the
  whole design**, not just for the parts we care about. That does not make the
  placement bad -- the router still minimises real routing delay -- but it means
  the tool cannot be trusted to trade off register-to-register paths correctly,
  and any design that closes only marginally on this flow should be treated as
  not closed at all until it is measured.

Related, and confirmed the same way: the XDC parser dispatches exactly two
commands, `set_property` and `create_clock`. There is no subset that includes
`set_false_path`, `set_max_delay` or `set_multicycle_path` -- so cross-domain
paths cannot be excluded, and every reported number includes them.
