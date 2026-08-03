# Loop 01 research: what an adversarial reviewer found, verified by hand

Four research lenses, each passed through a reviewer told to refute. Only the
findings I re-checked against the repository myself are listed here.

## Against our own claims

**The "274 DSP48" figure had no source.** `grep -rn "274"` across the repository
returns nothing. It was arithmetic (`4 * N * Fs / Fclk`), and it rested on a
115 MHz fabric clock that was never measured. The conclusion inverts with the
clock: at 128 taps and 61.44 MSPS it is 274 DSP48 at 115 MHz (does not fit) but
157 at 200 MHz (fits comfortably in 220). Quote the crossover as a range keyed
to the clock, or quote nothing.

**No design has ever been timing-constrained.** `create_clock` appears nowhere;
`build/ps7_corr.xdc` and `build/ps7_probe.xdc` are 0 bytes;
`build/REPRODUCTION.log` reports 186.05 MHz and 308.07 MHz for the same clock in
one file, both "PASS at 12.00 MHz" -- nextpnr's default when unconstrained.
`ps7_corr_timed.xdc` is a first attempt at fixing this.

**Part/speed-grade mismatch.** `run_openxc7.sh` builds `xc7z020clg400-1`;
`docs/FPGA_UTILIZATION_AND_COMPETITORS.md` says `XC7Z020-2CLG400I`. Different
bins, different timing.

**nextpnr's LUT denominator is 106400, not the industry-standard 53200 LUT6.**
Any utilisation percentage mixed with a Vivado-basis figure is off by 2x.

**The open flow has never touched radio infrastructure.** Verified: zero
`IBUFDS`, `ISERDESE2`, `OSERDESE2`, `IDELAYE2`, `MMCME2`, `PLLE2` instances in
any `.v` in the repository. Every "AD9361" hit in the RTL is a comment. The
proven design declares no ports at all.

## What this does to the roadmap

Putting the correlator into the live AD9361 datapath -- the step that turns a
384 kbit/s link into a video link -- needs all six of those primitive classes,
and openXC7 has never been shown to place and route a single one of them. That
is not a small integration task; it is the open question on which "fully open
flow" and "our RTL in the live radio path" may turn out to be mutually
exclusive on this device.

Sequence accordingly: constrain and re-measure first (free, and every number
downstream depends on it), fix `xc7frames2bit` determinism second (free, and it
is the only uncontested commercial differentiator), attempt the radio path
third, with the primitive-support question answered before any schedule is
promised.

## Superseded

One reviewer finding -- "the only correlator loaded into silicon failed,
`corr3.log`, 256 of 256 differ" -- was true when the research started and is no
longer. See `cstream2.log`: 256 of 256 bit-exact. The research and the bench
work ran in parallel.
