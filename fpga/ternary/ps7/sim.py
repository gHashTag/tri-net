#!/usr/bin/env python3
"""sim -- build and run every testbench here, and check what each one claims.

The board has been unreachable for several cycles, and in that time the
simulations became the main instrument: they found a duplicate declaration
synthesis had tolerated a dozen times, settled a capture lag that reasoning had
got wrong, explained two failing points of the rate sweep by measuring strobe
duty, and verified the real-pin design that silicon could not exercise. Running
them by hand, one at a time, was the last thing keeping that from being a
regression.

Each entry states what the run must show. Two of them are worth reading twice:

* `capture_duty` **must report mismatches** in its mixed-duty case. That bench
  exists to demonstrate that a constant-lag comparison fails when the strobe
  duty varies; a run in which it passed would mean the bench had stopped
  testing anything.

* `axi3_to_lite` must show its dead-slave case completing with a bus error
  rather than hanging. A bridge that stalls on an unresponsive slave hangs the
  CPU, and the only recovery is a power cycle.

A suite is worth what its ability to fail is worth, so `--selftest` injects a
fault and requires the suite to catch it. Getting that right took three
attempts, and the two failures are the interesting part:

* Editing a module's default parameter does nothing when the testbench overrides
  it -- `axi3_to_lite_tb.v` instantiates with `TIMEOUT(64)`.
* Inverting the sign of tap 7 does nothing, because tap 7's code is `2'b10` and
  the edit was on the `2'b01` branch. The injection landed on a line that index
  never reaches.

Both times the suite reported PASS, and both times that was correct: nothing was
broken. **A control that passes has to be checked for vacuity before it can be
read as evidence.** The self-test therefore asserts that its chosen tap really
does take the branch it edits.

Four questions, and the suite answers a different one in each mode. Running
them separately means the regression is only as complete as my memory of which
to run, so `--full` runs all four and gives one verdict:

    (default)    do the benches pass?
    --audit      is each checker at least as strict as the bench it wraps?
    --selftest   does an injected fault get caught?
    --matrix     which bench catches which fault?

Usage:
    ./sim.py            build and run every testbench
    ./sim.py --full     all four modes, one verdict -- this is the regression
    ./sim.py -v         also print each testbench's full output
    ./sim.py --audit    test the checkers against corrupted bench output
    ./sim.py --selftest inject a fault and require the suite to catch it
    ./sim.py --matrix   run every injection past every bench
    ./sim.py --seeds    run the property bench on many seeds, union coverage
"""

import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HDL = os.environ.get("ADI_HDL", "/tmp/a29/hdl")

# The correlator RTL lives one level up and is referenced there rather than
# copied: a duplicate is a second thing to keep in step, and the whole point of
# this suite is that the sources it checks are the sources that get built.
CORR = ["../tern_corr_pn.v", "../tern_corr_pn_tree.v"]
CORE = ["axi3_to_lite.v"] + CORR
VENDOR = ["library/axi_ad9361/*.v", "library/axi_ad9361/xilinx/*.v",
          "library/common/*.v", "library/xilinx/common/*.v"]


def expect_zero(out, pattern, label):
    """Every number captured by `pattern` must be zero."""
    hits = re.findall(pattern, out)
    if not hits:
        return False, f"{label}: no match for the expected line"
    bad = [h for h in hits if int(h) != 0]
    if bad:
        return False, f"{label}: {len(bad)} of {len(hits)} non-zero -> {bad[:4]}"
    return True, f"{label}: {len(hits)} checks, all zero"


def check_lag(out):
    ok, msg = True, []
    m = re.search(r"lag 1 : (\d+) mismatches", out)
    if not m or int(m.group(1)) != 0:
        return False, "lag 1 did not come out clean"
    msg.append("lag 1 clean")
    m0 = re.search(r"lag 0 : (\d+) mismatches", out)
    if not m0 or int(m0.group(1)) == 0:
        return False, "lag 0 also clean -- the bench cannot distinguish lags"
    msg.append("lag 0 rejected")
    # All four lags must be present: a run that stopped early leaves the first
    # two intact and would otherwise read as a pass.
    if len(re.findall(r"lag \d+ : \d+ mismatches", out)) < 4:
        return False, "the bench did not run to completion"
    return ok, ", ".join(msg)


def check_duty(out):
    sparse = re.search(r"sparse strobe.*?best lag (\d+), (\d+) mismatches", out)
    b2b = re.search(r"back-to-back.*?best lag (\d+), (\d+) mismatches", out)
    mixed = re.search(r"MIXED duty.*?best lag (\d+), (\d+) mismatches", out)
    if not (sparse and b2b and mixed):
        return False, "bench output did not match the expected shape"
    if int(sparse.group(2)) or int(b2b.group(2)):
        return False, "a uniform strobe should have a clean constant lag"
    if int(mixed.group(2)) == 0:
        return False, ("mixed duty came out clean -- this bench exists to show "
                       "that it cannot, so it has stopped testing anything")
    return True, (f"uniform strobes clean at lags {sparse.group(1)} and "
                  f"{b2b.group(1)}; mixed duty {mixed.group(2)} bad, as it must")


def check_bounds(out):
    c = re.search(r"checks = (\d+)", out)
    f = re.search(r"failures = (\d+)", out)
    if not (c and f):
        return False, "bench did not report counts"
    if int(f.group(1)):
        return False, f"{f.group(1)} boundary cases failed"
    if "the accumulator cannot overflow" not in out:
        return False, "the accumulator can overflow at these parameters"
    if int(c.group(1)) < 100:
        return False, f"only {c.group(1)} boundary checks"
    if "BOUNDS OK" not in out:
        return False, "the bench itself did not report OK"
    return True, (f"{c.group(1)} directed cases including the -32768 negation "
                  f"asymmetry; accumulator proven not to overflow")


def check_equiv(out):
    m = re.search(r"checks = (\d+)", out)
    x = re.search(r"full-scale samples exercised = (\d+)", out)
    e = re.search(r"mismatches = (\d+)", out)
    if not (m and e):
        return False, "bench did not report a count"
    if int(e.group(1)):
        return False, f"{e.group(1)} of {m.group(1)} disagree"
    if int(m.group(1)) < 2000:
        return False, f"only {m.group(1)} comparisons -- too few to mean much"
    if not x or int(x.group(1)) == 0:
        return False, "no full-scale samples were exercised"
    if "EQUIVALENCE OK" not in out:
        return False, "the bench itself did not report agreement"
    return True, (f"{m.group(1)} comparisons across 8 tap sets, "
                  f"{x.group(1)} at full scale, exact agreement")


def check_peak(want):
    """These benches assert an autocorrelation peak of a known exact value."""
    def _c(out):
        m = re.search(r"peak\s*=\s*(-?\d+)", out)
        if not m:
            return False, "no peak reported"
        got = int(m.group(1))
        if got != want:
            return False, f"peak {got}, expected exactly {want}"
        if "OK" not in out and "works" not in out:
            return False, "bench did not report success"
        return True, f"autocorrelation peak exactly {want}"
    return _c


def check_mac_tops(out):
    c = re.search(r"checks = (\d+)", out)
    f = re.search(r"failures = (\d+)", out)
    if not (c and f):
        return False, "bench did not report counts"
    if int(f.group(1)):
        return False, f"{f.group(1)} cases failed"
    if "MAC TOPS OK" not in out:
        return False, "the bench itself did not report OK"
    if int(c.group(1)) < 1000:
        return False, f"only {c.group(1)} checks -- the range sweep did not run"
    return True, (f"{c.group(1)} checks: all 256 sample values against three "
                  f"weight codes, -128 negation, heartbeat wiring")


def check_corr_tops(out):
    f = re.search(r"failures = (\d+)", out)
    lag = re.search(r"output lag measured: (\d+) samples \(8-tap\), (\d+)", out)
    if not f:
        return False, "bench did not report counts"
    if int(f.group(1)):
        return False, f"{f.group(1)} cases failed"
    if not lag:
        return False, "the pipeline lag was never measured"
    if lag.group(1) != lag.group(2):
        return False, (f"the two widths disagree on lag: {lag.group(1)} and "
                       f"{lag.group(2)}")
    if "CORR TOPS OK" not in out:
        return False, "the bench itself did not report OK"
    return True, (f"first sample not lost by the toggle ingest, -32768 "
                  f"negation, window sum; lag measured at {lag.group(1)} on "
                  f"both widths")


def check_speed(out):
    c = re.search(r"checks = (\d+)", out)
    f = re.search(r"failures = (\d+)", out)
    n = re.search(r"compared = (\d+)", out)
    if not (c and f and n):
        return False, "bench did not report counts"
    if int(f.group(1)):
        return False, f"{f.group(1)} cases failed"
    if int(n.group(1)) != 256:
        return False, (f"{n.group(1)} outputs compared -- the ROM holds 256 and "
                       f"a pass that checks fewer is not a full pass")
    if "SPEED HARNESS OK" not in out:
        return False, "the bench itself did not report OK"
    return True, ("the throughput harness starts from a cold request and "
                  "compares all 256 ROM outputs with no errors")


def check_nco(out):
    c = re.search(r"checks = (\d+)", out)
    f = re.search(r"failures = (\d+)", out)
    if not (c and f):
        return False, "bench did not report counts"
    if int(f.group(1)):
        return False, f"{f.group(1)} cases failed"
    if "NCO OK" not in out:
        return False, "the bench itself did not report OK"
    if "period matches the carrier table" not in out:
        return False, "the carrier period was not confirmed"
    return True, (f"{c.group(1)} cases: carrier period, BPSK inversion, "
                  f"ternary levels, phase hold")


def check_loop(out):
    m = re.search(r"data1 peak=(-?\d+), data0 peak=(-?\d+)", out)
    if not m:
        return False, "no peak pair reported"
    p1, p0 = int(m.group(1)), int(m.group(2))
    if p1 != 600 or p0 != -600:
        return False, (f"peaks {p1}/{p0}; the carrier has six non-zero entries "
                       f"so a matched peak must be exactly 6*AMP = 600")
    if "loop closes" not in out:
        return False, "the bench did not report the loop closing"
    return True, "TX to RX: peak exactly 6*AMP and its sign follows the data bit"


def check_corr8(out):
    m = re.search(r"DC \(orth\) peak corr = (-?\d+)", out)
    if not m:
        return False, "no DC rejection figure reported"
    if int(m.group(1)) != 0:
        return False, f"DC leaked through: {m.group(1)}, expected 0"
    if "works" not in out:
        return False, "bench did not report success"
    return True, "matched code peaks and DC nulls exactly"


def check_dot27(out):
    c = re.search(r"checks = (\d+)", out)
    b = re.search(r"boundary cases = (\d+)", out)
    e = re.search(r"mismatches = (\d+)", out)
    if not (c and e):
        return False, "bench did not report counts"
    if int(e.group(1)):
        return False, f"{e.group(1)} of {c.group(1)} disagree with the model"
    if not b or int(b.group(1)) == 0:
        return False, "no boundary case was exercised"
    if "DOT27 EQUIVALENCE OK" not in out:
        return False, "the bench itself did not report agreement"
    if int(c.group(1)) < 800:
        return False, f"only {c.group(1)} comparisons"
    return True, (f"{c.group(1)} comparisons including the -128 negation "
                  f"asymmetry and a single-weight sweep")


def check_matvec(out):
    m = re.search(r"(\d+) trials x (\d+) neurons, (\d+) mismatches", out)
    if not m:
        return False, "no trial summary reported"
    if int(m.group(3)) != 0:
        return False, f"{m.group(3)} mismatches"
    if "bit-exact" not in out or "works" not in out:
        return False, "the bench itself did not report success"
    return True, (f"{m.group(1)} trials x {m.group(2)} neurons, bit-exact "
                  f"against the reference")


def check_gain(out):
    """The coverage matrix found this checker blind, not the bench.

    An injection adding one to every positive tap moves the autocorrelation
    sidelobes from -100 to -68 and makes the bench print FAILED -- but the
    'processing gain = 63x' line is identical either way, and that line was all
    this looked at. Reading one number out of a bench that prints a verdict is
    how a checker ends up weaker than the test it wraps.
    """
    if "FAILED" in out:
        return False, "the bench itself reported failure"
    m = re.search(r"processing gain = (\d+)x", out)
    if not m:
        return False, "no processing gain reported"
    if int(m.group(1)) != 63:
        return False, f"gain {m.group(1)}x, expected 63x for a 63-chip code"
    side = re.findall(r"autocorr shift \d+\s*=\s*(-?\d+)", out)
    if not side:
        return False, "no sidelobe values reported"
    bad = [v for v in side if int(v) != -100]
    if bad:
        return False, (f"sidelobes {bad[:3]} -- a 63-chip m-sequence must give "
                       f"exactly -100 at every non-zero shift")
    if "works" not in out:
        return False, "bench did not report success"
    return True, (f"gain exactly 63x and all {len(side)} sidelobes exactly "
                  f"-100, as an m-sequence requires")


def check_spi_bounds(out):
    c = re.search(r"checks = (\d+)", out)
    f = re.search(r"failures = (\d+)", out)
    if not (c and f):
        return False, "bench did not report counts"
    if int(f.group(1)):
        return False, f"{f.group(1)} boundary cases failed"
    if "SPI BOUNDS OK" not in out:
        return False, "bench did not report OK"
    return True, (f"{c.group(1)} cases: edge count, chip-select framing, "
                  f"start-during-busy, reset mid-transfer and recovery")


def check_spi(out):
    if "SPI MASTER OK" not in out:
        return False, "spi testbench did not report OK"
    if "HANG" in out:
        return False, "a transfer never completed"
    e = re.search(r"errors: (\d+)", out)
    if not e:
        return False, "no error count reported"
    if int(e.group(1)):
        return False, f"{e.group(1)} errors reported alongside the OK line"
    return True, "bit order, sampling edge, duplex and chip-select framing"


def check_ctrlplane(out):
    if "CONTROL PLANE OK" not in out:
        return False, "control-plane testbench did not report OK"
    return True, "control pins follow their register; a write becomes a transfer"


def check_props(out):
    o = re.search(r"observations = (\d+)", out)
    v = re.search(r"violations = (\d+)", out)
    if not (o and v):
        return False, "bench did not report counts"
    if int(v.group(1)):
        return False, f"{v.group(1)} invariant violations"
    if "BUS PROPERTIES OK" not in out:
        return False, "the bench itself did not report OK"
    if int(o.group(1)) < 500:
        return False, f"only {o.group(1)} observations -- too little traffic"
    if "VACUOUS" in out:
        return False, "a channel carried no traffic, so its monitors saw nothing"
    w = re.search(r"writes started (\d+), answered (\d+)", out)
    r = re.search(r"reads started (\d+), answered (\d+)", out)
    if not (w and r) or int(w.group(1)) == 0 or int(r.group(1)) == 0:
        return False, "one of the channels carried no traffic"
    st = re.search(r"cycles with backpressure = (\d+)", out)
    ov = re.search(r"cycles with read and write both outstanding = (\d+)", out)
    if not st or int(st.group(1)) == 0:
        return False, ("the slave never stalled, so nothing about waiting for "
                       "ready was tested")
    if not ov or int(ov.group(1)) == 0:
        return False, "read and write never overlapped"
    return True, (f"{o.group(1)} observations over {w.group(1)} writes and "
                  f"{r.group(1)} reads, {st.group(1)} stalled cycles and "
                  f"{ov.group(1)} overlapped, no invariant broken")


def check_bridge_bounds(out):
    c = re.search(r"checks = (\d+)", out)
    f = re.search(r"failures = (\d+)", out)
    if not (c and f):
        return False, "bench did not report counts"
    if int(f.group(1)):
        return False, f"{f.group(1)} boundary cases failed"
    if "BRIDGE BOUNDS OK" not in out:
        return False, "bench did not report OK"
    return True, (f"{c.group(1)} cases: byte enables honoured end to end, ids "
                  f"echoed per transaction, 16-beat burst, back-to-back")


def check_bridge(out):
    if "BRIDGE OK" not in out:
        return False, "bridge testbench did not report OK"
    if "HANG" in out:
        return False, "a transaction hung -- that is the failure that costs a "\
                      "power cycle"
    e = re.search(r"errors: (\d+)", out)
    if not e:
        return False, "no error count reported"
    if int(e.group(1)):
        return False, f"{e.group(1)} errors reported alongside the OK line"
    return True, "single beats, bursts, ID echo, and a dead slave answered"


def check_fullpath(out):
    ok, msg = expect_zero(out, r"per-sample lag: (\d+) bad", "rate sweep")
    if not ok:
        return ok, msg
    ok2, msg2 = expect_zero(out, r"per-sample (\d+) bad", "phase sweep")
    if "5a5a47c0" not in out.lower():
        return False, "bridge magic wrong"
    if "000a0300" not in out.lower():
        return False, "ADI version wrong"
    return ok and ok2, f"{msg}; {msg2}; magic and version correct"


def check_realpin(out):
    m = re.search(r"per-sample lag: (\d+) mismatches", out)
    if not m or int(m.group(1)) != 0:
        return False, "capture did not match the model"
    o = re.search(r"other: (\d+)", out)
    if not o or int(o.group(1)) != 0:
        return False, "captured samples were not all PN chips"
    if "any_nonzero 1" not in out:
        return False, "no data reached the correlator"
    return True, "all samples are PN chips, capture bit-exact"


# `..` is fpga/ternary. These benches were in the tree and not in the suite,
# which meant the correlator core -- the part with a published claim attached --
# was checked by two benches while five more sat unused beside them.
T = "../"

BENCHES = [
    ("corr_bounds", [T+"corr_bounds_tb.v", T+"tern_corr_pn_tree.v",
                     T+"tern_corr_pn.v"], [], check_bounds),
    ("corr_equiv", [T+"corr_equiv_tb.v", T+"tern_corr_pn_tree.v",
                    T+"tern_corr_pn.v"], [], check_equiv),
    ("pn_despread", [T+"tern_pn_tb.v", T+"tern_pn_lfsr.v", T+"tern_corr_pn.v"],
     [], check_gain),
    ("corr_tree", [T+"tern_corr_pn_tree_tb.v", T+"tern_corr_pn_tree.v"], [],
     check_peak(6300)),
    # tern_corr_pn_stream is a standalone implementation -- it does not
    # instantiate tern_corr_pn, which is why it is immune to injections into
    # that file. Passing the file anyway made the matrix look like a coverage
    # gap where there was none.
    ("corr_stream", [T+"tern_corr_pn_stream_tb.v", T+"tern_corr_pn_stream.v"],
     [], check_peak(6300)),
    ("mac_tops", ["mac_tops_tb.v", "ps7_tern.v", "ps7_probe.v", "sim_stubs.v"],
     [], check_mac_tops),
    ("corr_tops", ["corr_tops_tb.v", "ps7_corr.v", "ps7_pn.v", "sim_stubs.v",
                   T+"tern_corr8_stream.v", T+"tern_corr8.v",
                   T+"tern_corr_pn_stream.v", T+"tern_corr_pn.v"], [],
     check_corr_tops),
    ("speed_harness", ["speed_tb.v", "ps7_speed.v", "sim_stubs.v",
                       T+"tern_corr_pn_tree.v"], [], check_speed),
    ("nco", [T+"tern_nco_tb.v", T+"tern_nco.v"], [], check_nco),
    ("tx_rx_loop", [T+"tern_loop_tb.v", T+"tern_nco.v", T+"tern_corr8_stream.v",
                    T+"tern_corr8.v"], [], check_loop),
    ("corr8_stream", [T+"tern_corr8_stream_tb.v", T+"tern_corr8_stream.v",
                      T+"tern_corr8.v"], [], check_corr8),
    ("dot27_equiv", [T+"dot27_equiv_tb.v", T+"tern_dot27.v"], [], check_dot27),
    ("matvec", [T+"tern_matvec_tb.v", T+"tern_matvec.v", T+"tern_dot27.v"], [],
     check_matvec),
    ("spi_bounds", ["spi_bounds_tb.v", "spi_master.v"], [], check_spi_bounds),
    ("spi_master", ["spi_master_tb.v", "spi_master.v"], [], check_spi),
    ("ctrlplane", ["ctrlplane_tb.v", "sim_stubs.v", "ps7_ad9361_ctrl.v",
                   "spi_master.v"] + CORE, VENDOR, check_ctrlplane),
    ("bus_props", ["bus_props_tb.v", "axi3_to_lite.v", "spi_master.v"], [],
     check_props),
    ("bridge_bounds", ["bridge_bounds_tb.v", "axi3_to_lite.v"], [],
     check_bridge_bounds),
    ("axi3_to_lite", ["axi3_to_lite_tb.v", "axi3_to_lite.v"], [], check_bridge),
    ("capture_lag", ["capture_lag_tb.v", "../tern_corr_pn_tree.v"], [],
     check_lag),
    ("capture_duty", ["capture_duty_tb.v", "../tern_corr_pn_tree.v"], [],
     check_duty),
    ("fullpath", ["fullpath_tb.v", "sim_stubs.v", "ps7_ad9361_rate.v"] + CORE,
     VENDOR, check_fullpath),
    ("realpin", ["realpin_tb.v", "sim_stubs.v", "ps7_ad9361_real.v"] + CORE,
     VENDOR, check_realpin),
]


def run(name, local, vendor, checker, verbose):
    import glob
    srcs = []
    for f in local:
        p = os.path.join(HERE, f)
        if not os.path.exists(p):
            return None, f"missing source {f}"
        srcs.append(p)
    for pat in vendor:
        hits = glob.glob(os.path.join(HDL, pat))
        if not hits:
            return None, (f"vendor sources missing at {HDL} -- restore with "
                          f"'git clone https://github.com/analogdevicesinc/hdl' "
                          f"and set ADI_HDL, or point ADI_HDL at an existing "
                          f"checkout")
        srcs += hits

    exe = f"/tmp/sim_{name}"
    b = subprocess.run(["iverilog", "-g2005", "-o", exe] + srcs,
                       capture_output=True, text=True)
    errs = [l for l in (b.stdout + b.stderr).splitlines()
            if "error" in l.lower() and "warning" not in l.lower()]
    if b.returncode != 0:
        return None, "compile failed: " + (errs[0] if errs else "unknown")

    r = subprocess.run([exe], capture_output=True, text=True, timeout=1800)
    out = r.stdout + r.stderr
    if verbose:
        print(out)
    if "TIMEOUT" in out:
        return False, "testbench timed out"
    return checker(out)


# One injection per bench, each aimed at what that bench exists to catch.
# `note` records why the edited line is actually reached, because two earlier
# attempts at this were vacuous: one edited a default parameter the testbench
# overrides, the other a branch the chosen index never takes.
INJECTIONS = [
    dict(name="tap sign",
         file=os.path.join(HERE, "..", "tern_corr_pn_tree.v"),
         frm="assign term[i] = (tp[i] == 2'b01) ?  sx :",
         to="assign term[i] = (tp[i] == 2'b01) ? ((i==1) ? -sx : sx) :",
         benches=["capture_lag", "capture_duty", "fullpath", "realpin"],
         note="tap 1's code is 2'b01, so it takes the edited branch"),
    dict(name="negate before sign-extend",
         file=os.path.join(HERE, "..", "tern_corr_pn.v"),
         frm="2'b10: acc = acc - {{(ACC-W){xi[W-1]}}, xi};",
         to="2'b10: begin xi = -xi; acc = acc + {{(ACC-W){xi[W-1]}}, xi}; end",
         benches=["corr_bounds", "corr_equiv"],
         note="-32768 has no positive counterpart at 16 bits, so negating "
              "before extending gives -32768 where +32768 is required"),
    dict(name="combinational correlator sign",
         file=os.path.join(HERE, "..", "tern_corr_pn.v"),
         frm="2'b01: acc = acc + {{(ACC-W){xi[W-1]}}, xi};",
         to="2'b01: acc = acc + {{(ACC-W){xi[W-1]}}, xi} + 1;",
         benches=["corr_equiv"],
         note="every positive tap would contribute one too much, and the tree "
              "would not follow"),
    dict(name="ingest only on a rising strobe",
         file=os.path.join(HERE, "ps7_pn.v"),
         frm="wire s_valid = strobe_sync[1] ^ strobe_d;   // one pulse per toggle",
         to="wire s_valid = strobe_sync[1] & ~strobe_d;",
         benches=["corr_tops"],
         note="halves the ingest rate, so every other sample is dropped"),
    dict(name="start request dropped during init",
         file=os.path.join(HERE, "ps7_speed.v"),
         frm="    wire go_pulse = (go_edge & taps_done) | (go_pending & taps_done);",
         to="    wire go_pulse = go_edge;",
         benches=["speed_harness"],
         note="restores the old behaviour, where a start issued before the "
              "taps are loaded is lost and the host waits forever"),
    dict(name="carrier table entry",
         file=os.path.join(HERE, "..", "tern_nco.v"),
         frm="3'd2: carrier = Z;  3'd3: carrier = M;",
         to="3'd2: carrier = P;  3'd3: carrier = M;",
         benches=["nco", "tx_rx_loop"],
         note="a zero entry becoming +1 changes the period and the matched "
              "peak from 6*AMP to 7*AMP"),
    dict(name="matvec accumulator",
         file=os.path.join(HERE, "..", "tern_dot27.v"),
         frm="assign node[g] = node[2*g] + node[2*g+1];",
         to="assign node[g] = node[2*g] - node[2*g+1];",
         benches=["matvec", "dot27_equiv"],
         note="the adder tree would subtract its right child instead of adding"),
    dict(name="reset leaves chip select asserted",
         file=os.path.join(HERE, "spi_master.v"),
         frm="      busy <= 1'b0; spi_csn <= 1'b1; spi_clk <= 1'b0; spi_mosi <= 1'b0;",
         to="      busy <= 1'b0; spi_clk <= 1'b0; spi_mosi <= 1'b0;",
         benches=["spi_bounds", "spi_master", "bus_props"],
         note="a reset mid-transfer would leave the slave selected; the older "
              "bench never resets mid-transfer and does not see this"),
    dict(name="request withdrawn before acceptance",
         file=os.path.join(HERE, "axi3_to_lite.v"),
         frm="    if (m_awready) m_awvalid <= 0;",
         to="    m_awvalid <= 0;",
         benches=["bus_props", "bridge_bounds"],
         note="a protocol violation the transaction bench sees only as "
              "corrupted data, and the older bench does not see at all"),
    dict(name="byte enables dropped",
         file=os.path.join(HERE, "axi3_to_lite.v"),
         frm="m_wdata  <= s_wdata; m_wstrb <= s_wstrb; m_wvalid <= 1;",
         to="m_wdata  <= s_wdata; m_wstrb <= 4'hF; m_wvalid <= 1;",
         benches=["bridge_bounds", "axi3_to_lite", "bus_props"],
         note="every partial write would become a full-word write; the older "
              "bench does not notice, which is why the new one exists"),
    dict(name="bridge read timeout",
         file=os.path.join(HERE, "axi3_to_lite.v"),
         frm="end else if (rtmo == TIMEOUT) begin",
         to="end else if (1'b0) begin",
         benches=["axi3_to_lite", "bridge_bounds"],
         note="the dead-slave read must then hang instead of answering"),
    dict(name="per-sample lag bit",
         file=os.path.join(HERE, "ps7_ad9361_rate.v"),
         frm="pv_mem [cap_idx[6:0]] <= prev_valid;",
         to="pv_mem [cap_idx[6:0]] <= 1'b0;",
         benches=["fullpath"],
         note="the rates with a back-to-back strobe must then mismatch"),
    dict(name="spi bit order",
         file=os.path.join(HERE, "spi_master.v"),
         frm="shift_in <= {shift_in[WIDTH-2:0], spi_miso};",
         to="shift_in <= {spi_miso, shift_in[WIDTH-1:1]};",
         benches=["spi_master", "spi_bounds"],
         note="MISO would then assemble least-significant bit first"),
    dict(name="control register",
         file=os.path.join(HERE, "ps7_ad9361_ctrl.v"),
         frm="if (m_awaddr[9:2] == 8'h0E) radio_ctl <= m_wdata[2:0];",
         to="if (m_awaddr[9:2] == 8'h0E) radio_ctl <= 3'b000;",
         benches=["ctrlplane"],
         note="resetb, enable and txnrx would stop following their register"),
    dict(name="captured sample",
         file=os.path.join(HERE, "ps7_ad9361_real.v"),
         frm="in_mem[in_idx[6:0]] <= o_adc_data_i0;",
         to="in_mem[in_idx[6:0]] <= o_adc_data_i0 ^ 16'h0001;",
         benches=["realpin"],
         note="one bit of every recorded sample is wrong"),
]


def selftest(verbose):
    """Inject one fault per bench and require the right bench to catch it."""
    failures = 0
    unproven = []
    for inj in INJECTIONS:
        original = open(inj["file"]).read()
        if inj["frm"] not in original:
            print(f"  [{inj['name']}] target not present -- this control would "
                  f"be vacuous, which is how two earlier ones passed")
            failures += 1
            continue
        print(f"  [{inj['name']}] {inj['note']}")
        try:
            open(inj["file"], "w").write(
                original.replace(inj["frm"], inj["to"], 1))
            caught, skipped = [], []
            for name, local, vendor, checker in BENCHES:
                if name not in inj["benches"]:
                    continue
                ok, why = run(name, local, vendor, checker, verbose)
                if ok is None:
                    skipped.append(name)
                    continue
                caught.append(ok is False)
                if verbose or ok is not False:
                    print(f"      {name}: "
                          f"{'caught' if ok is False else 'did NOT CATCH it'}")
            hit = sum(1 for c in caught if c)
            if skipped:
                print(f"      {len(skipped)} bench(es) could not run: "
                      f"{', '.join(skipped)}")
            if not caught:
                # A bench that could not run has not missed anything. Counting
                # it as a failure would say the suite is blind when in fact it
                # was absent -- the same conflation the SKIP/PASS split exists
                # to avoid.
                print(f"      no bench could run -- unproven, not failed")
                unproven.append(inj["name"])
            else:
                print(f"      caught by {hit} of {len(caught)} benches")
                if not hit:
                    failures += 1
        finally:
            open(inj["file"], "w").write(original)
    if failures:
        print(f"  SELFTEST FAIL -- {failures} injections were run past a live "
              f"bench and went unnoticed")
        return 1
    proven = len(INJECTIONS) - len(unproven)
    if unproven:
        print(f"  SELFTEST PARTIAL -- {proven} injections caught; "
              f"{len(unproven)} could not be tested because their benches "
              f"cannot build: {', '.join(unproven)}")
        return 2
    print(f"  SELFTEST PASS -- all {len(INJECTIONS)} injections were caught")
    return 0


# Mutations applied to a bench's own output, to test the checker rather than
# the bench. Cycle 59 found a checker that read one number out of a bench that
# prints its own verdict -- and that number was invariant under the fault. The
# bench said FAILED; the wrapper said PASS.
OUTPUT_MUTATIONS = [
    ("empty output", lambda t: ""),
    # By lines, not characters: a short output truncated by characters keeps
    # almost everything, verdict included, and a checker that accepts it is
    # right to. The mutation has to remove evidence to test anything.
    ("truncated to the first half of its lines",
     lambda t: "\n".join(t.splitlines()[:max(1, len(t.splitlines()) // 2)])),
    ("verdict flipped to failure",
     lambda t: re.sub(r"\bOK\b", "FAILED", t)
                 .replace("works", "FAILED")
                 .replace("bit-exact", "FAILED")),
    ("a reported count changed from zero to one",
     lambda t: re.sub(r"((?:failures|mismatches|errors)\s*[:=]\s*)0\b",
                      r"\g<1>1", t)),
]


def audit(verbose):
    """Test every checker against mutated output from its own bench.

    A checker is supposed to be at least as strict as the bench it wraps. This
    runs each bench once for real, then feeds its checker deliberately corrupted
    versions of that output and requires a rejection each time. A mutation that
    slips through names a checker that is not reading what the bench is saying.
    """
    failures = 0
    for name, local, vendor, checker in BENCHES:
        ok, msg = run(name, local, vendor, checker, False)
        if ok is None:
            print(f"  [{name}] cannot build -- checker untested")
            continue
        if not ok:
            print(f"  [{name}] bench does not pass to begin with: {msg}")
            failures += 1
            continue
        # capture the genuine output once
        import glob as _g
        srcs = [os.path.join(HERE, f) for f in local]
        for pat in vendor:
            srcs += _g.glob(os.path.join(HDL, pat))
        exe = f"/tmp/sim_{name}"
        text = subprocess.run([exe], capture_output=True, text=True,
                              timeout=1800).stdout
        slipped, vacuous = [], []
        for label, mut in OUTPUT_MUTATIONS:
            mutated = mut(text)
            if mutated == text:
                # The mutation did not change anything, so accepting it says
                # nothing about the checker. Counting it as a failure would be
                # the same vacuity this suite keeps rediscovering.
                vacuous.append(label)
                continue
            mok, _ = checker(mutated)
            if mok:
                slipped.append(label)
        applied = len(OUTPUT_MUTATIONS) - len(vacuous)
        note = f" ({len(vacuous)} not applicable)" if vacuous else ""
        if slipped:
            print(f"  [{name}] ACCEPTS corrupted output: "
                  f"{'; '.join(slipped)}{note}")
            failures += 1
        else:
            print(f"  [{name}] rejects all {applied} applicable "
                  f"mutations{note}")
    print()
    if failures:
        print(f"CHECKER AUDIT FAIL -- {failures} checkers are weaker than their "
              f"benches")
        return 1
    print("CHECKER AUDIT PASS -- every checker rejects corrupted output")
    return 0


ALL_BINS = ["aw_stall", "w_stall", "ar_stall", "b_wait", "r_wait", "overlap",
            "spi_reset_mid_transfer", "spi_back_to_back"] + \
           [f"strb{i}" for i in range(16)] + \
           ["x_awstall_with_read", "x_wstall_with_read",
            "x_bwait_with_arstall", "x_both_responses_waiting",
            "x_spi_during_bus_stall", "x_spireset_during_bus_stall",
            "x_partial_write_stalled",
            "x3_partial_with_both_responses_held",
            "x3_spireset_with_both_responses_held",
            "x_aw_stalled_four_cycles", "x_w_stalled_four_cycles",
            "x_response_held_four_cycles"]


def seeds(verbose, count=24):
    """Run the property bench across many seeds and union its coverage.

    One seed says the invariants held on one random walk. Many seeds, with the
    reached states unioned, say something different and more useful: which
    states the traffic never reaches at all. A bin that is never hit is not a
    passing test -- it is an untested state wearing a passing test's clothes,
    which is the failure mode this suite has found in itself five times now.
    """
    entry = [b for b in BENCHES if b[0] == "bus_props"]
    if not entry:
        print("  no property bench")
        return 1
    name, local, vendor, checker = entry[0]
    ok, msg = run(name, local, vendor, checker, False)
    if ok is None:
        print(f"  cannot build: {msg}")
        return 2
    hit = set()
    viol = 0
    for i in range(count):
        r = subprocess.run([f"/tmp/sim_{name}", f"+seed={1234 + i * 7919}"],
                           capture_output=True, text=True, timeout=1800)
        out = r.stdout
        m = re.search(r"^COVERAGE(.*)$", out, re.M)
        if m:
            hit |= set(m.group(1).split())
        v = re.search(r"violations = (\d+)", out)
        if v and int(v.group(1)):
            viol += int(v.group(1))
            print(f"  seed {1234 + i * 7919}: {v.group(1)} violations")
    missing = [b for b in ALL_BINS if b not in hit]
    print(f"  {count} seeds, {len(hit)} of {len(ALL_BINS)} states reached")
    if viol:
        print(f"  {viol} invariant violations across the run")
        return 1
    if missing:
        print(f"  never reached: {', '.join(missing)}")
        print("  those states are untested -- the traffic cannot create them")
        return 2
    if len(hit) < len(ALL_BINS):
        return 2
    print("  every state reached, no invariant broken")
    return 0


# Every number this project states, with the bench that produces it and the
# value it must produce. A claim that cannot be re-derived from a run is an
# opinion; this table is what makes the difference checkable.
#
# `note` is the reasoning that makes the value the RIGHT one -- 600 is not
# simply what came out, it is 6*AMP because the carrier has six non-zero
# entries, and a run producing 800 would mean the carrier changed, not that the
# number needs updating.
FACTS = [
    dict(claim="correlator pipeline lag", bench="corr_tops",
         pattern=r"output lag measured: (\d+) samples", value="1",
         note="the registered output reflects the window ending one sample "
              "back; measured independently on the 8-tap and 63-tap designs "
              "and equal on both"),
    # This number was first written down as evidence that the carrier has six
    # non-zero entries. It is not: the loop bench takes the receiver's taps
    # from the same definition as the transmitter, so altering the carrier
    # moves both sides together and the peak does not budge -- the facts check
    # itself demonstrated that by failing to notice an injected change. What
    # the figure does show is that the loop closes and the peak's sign follows
    # the data bit. The carrier's structure is stated separately, from a bench
    # that can actually see it.
    dict(claim="matched-filter peak, TX to RX loop", bench="tx_rx_loop",
         pattern=r"data1 peak=(-?\d+)", value="600",
         note="the TX->RX loop closes and the peak's sign follows the data "
              "bit; this figure does NOT witness the carrier's structure, "
              "because both sides of the loop share one definition"),
    dict(claim="non-zero carrier entries per period", bench="nco",
         pattern=r"nonzero_entries = (\d+)", value="6",
         note="sign(cos(2*pi*k/8)) is zero at k=2 and k=6; measured on the "
              "generator's own output, which is why this one does move when "
              "the carrier table is altered"),
    dict(claim="PN processing gain", bench="pn_despread",
         pattern=r"processing gain = (\d+)x", value="63",
         note="a 63-chip m-sequence gives peak/off-peak of exactly N"),
    dict(claim="PN autocorrelation sidelobe", bench="pn_despread",
         pattern=r"autocorr shift 1\s*=\s*(-?\d+)", value="-100",
         note="an m-sequence has a flat sidelobe of -A at every non-zero shift"),
    dict(claim="tree despreader peak", bench="corr_tree",
         pattern=r"peak\s*=\s*(\d+)", value="6300",
         note="N*A = 63*100"),
    dict(claim="streaming despreader peak", bench="corr_stream",
         pattern=r"peak\s*=\s*(\d+)", value="6300",
         note="the same figure from an implementation sharing no code"),
    dict(claim="throughput harness comparisons", bench="speed_harness",
         pattern=r"compared = (\d+)", value="256",
         note="the fabric ROM holds 256 samples; a pass comparing fewer is not "
              "a full pass and its throughput figure would not stand"),
    dict(claim="pipelined vs combinational correlator agreement",
         bench="corr_equiv", pattern=r"checks = (\d+)", value="2688",
         note="8 tap sets x 336 comparisons, all exact, between two "
              "implementations sharing no code"),
    dict(claim="dot-product core agreement", bench="dot27_equiv",
         pattern=r"checks = (\d+)", value="859",
         note="random corpus plus the -128 negation asymmetry and a "
              "single-weight sweep across all 27 positions"),
    dict(claim="correlator boundary cases", bench="corr_bounds",
         pattern=r"checks = (\d+)", value="131",
         note="includes the case where negating -32768 before widening returns "
              "the input unchanged"),
    # Not a bench: a capture taken on silicon and committed, re-derived here
    # from the file. This is the one hardware result that survives the board
    # being unreachable, because the measurement was written down rather than
    # left in /tmp -- unlike the vendor bitstream, which was not.
    dict(claim="golden vector, fully-determined outputs", cmd=[
             "verify_in_datapath.py", "golden/pn63_matched.txt"],
         pattern=r"(\d+)/\d+ bit-exact", value="63",
         note="every output whose window lies entirely inside the capture. "
              "Reports before cycle 73 said 65: the per-sample lag added in "
              "cycle 44 can be 2, which makes outputs 0..64 depend on samples "
              "taken before recording began, not 0..62. The check became "
              "narrower and more correct; the published figure was never "
              "recomputed, and this table is what caught it"),
    dict(claim="golden vector, matched-filter peak", cmd=[
             "verify_in_datapath.py", "golden/pn63_matched.txt"],
         pattern=r"largest magnitude: (\d+)", value="128961",
         note="63*2047, the accumulator's true maximum for a 63-tap matched "
              "filter at full chip amplitude"),
    dict(claim="MAC top-level checks", bench="mac_tops",
         pattern=r"checks = (\d+)", value="1291",
         note="all 256 sample values against three weight codes, on two "
              "designs at once"),
]


def write_facts_doc(path):
    """Generate the document from the same table the check reads.

    Two copies of a number drift; one copy cannot. The document is an output of
    the table, never a hand-maintained parallel record.
    """
    lines = [
        "# Measured facts",
        "",
        "Every number here is produced by a testbench in this directory and is",
        "re-derived by `./sim.py --facts`. Nothing in this file is typed in by",
        "hand -- it is generated from the table in `sim.py`, so the document",
        "and the check cannot disagree.",
        "",
        "A number that changes is not a number to update here. It means the",
        "design changed, and the reason column says what would have to be true",
        "for the new value to be right.",
        "",
        "| value | claim | bench | why this value and not another |",
        "|---|---|---|---|",
    ]
    for f in FACTS:
        src = f.get("bench") or f["cmd"][0]
        lines.append(f"| `{f['value']}` | {f['claim']} | `{src}` | "
                     f"{f['note']} |")
    lines += [
        "",
        "## Stated from hardware, and not re-derivable today",
        "",
        "These came from runs on the board. The board has been unreachable",
        "since cycle 52, so none of them can be re-derived the way the table",
        "above can. They are listed with what would be needed to restate them,",
        "because a number nobody can reproduce should say so on its face.",
        "",
        "| value | claim | how it was obtained | what it would take to restate |",
        "|---|---|---|---|",
        "| `83.3 MHz` | standalone correlator Fmax, silicon | swept on the "
        "board until the self-test failed | the board, and `ps7_speed` |",
        "| `50 MHz` | correlator in the vendor datapath, clean | rate sweep "
        "with a fabric clock divider | the board, and `ps7_ad9361_rate` |",
        "| `62 of 64` | outputs matching at 62.5 MHz | the same sweep | the "
        "board; and note this was under the constant-lag reading, which cycle "
        "44 showed to be wrong at that rate |",
        "| `256 of 256` | bit-exact at 8 and 63 taps | one sample per devmem "
        "write | the board |",
        "| `1219` | sample pairs bit-exact in the datapath | accumulated over "
        "several captures | the board |",
        "",
        "One hardware result did survive: the golden vector, in the table",
        "above. It survived because the capture was committed to the",
        "repository rather than left in `/tmp` -- unlike the vendor bitstream,",
        "which was not, and is gone.",
        "",
        "## Not measured anywhere yet",
        "",
        "The receive path on real pins. `realpin` verifies the design is",
        "correct when a signal arrives; that a signal arrives at all needs the",
        "control plane, which needs pins this project has not identified.",
        "",
    ]
    open(path, "w").write("\n".join(lines) + "\n")


def facts(verbose):
    """Re-derive every stated number from a run of the bench that produces it."""
    bad = 0
    for f in FACTS:
        if "cmd" in f:
            r = subprocess.run([sys.executable] + f["cmd"], cwd=HERE,
                               capture_output=True, text=True, timeout=600)
            m = re.search(f["pattern"], r.stdout + r.stderr)
            got = m.group(1) if m else None
            if got != f["value"]:
                print(f"  [{f['claim']}] states {f['value']}, run gives {got}")
                bad += 1
            else:
                print(f"  {f['value']:>6}  {f['claim']}  ({f['cmd'][0]})")
            continue
        entry = [b for b in BENCHES if b[0] == f["bench"]]
        if not entry:
            print(f"  [{f['claim']}] no bench named {f['bench']}")
            bad += 1
            continue
        name, local, vendor, checker = entry[0]
        ok, why = run(name, local, vendor, checker, False)
        if ok is None:
            print(f"  [{f['claim']}] bench cannot build -- unverified")
            continue
        out = subprocess.run([f"/tmp/sim_{name}"], capture_output=True,
                             text=True, timeout=1800).stdout
        m = re.search(f["pattern"], out)
        got = m.group(1) if m else None
        if got != f["value"]:
            print(f"  [{f['claim']}] states {f['value']}, run gives {got}")
            bad += 1
        else:
            print(f"  {f['value']:>6}  {f['claim']}  ({f['bench']})")
    print()
    if bad:
        print(f"FACTS FAIL -- {bad} stated numbers no longer match a run")
        return 1
    write_facts_doc(os.path.join(HERE, "FACTS.md"))
    print(f"FACTS PASS -- all {len(FACTS)} numbers re-derived from their "
          f"benches; FACTS.md regenerated")
    return 0


def matrix(verbose):
    """Run every injection past every bench, not just its declared ones.

    Cycle 58 assumed the older SPI bench would be blind to a protocol fault the
    way the older bridge bench was blind to byte enables. It was not -- it
    caught both data-level injections and missed only the reset case. The
    assumption was wrong in both directions, so this stops assuming: what
    catches what is measured.

    Two things it can show that per-injection testing cannot. A fault caught by
    exactly one bench is a single point of failure in the suite. A bench that
    catches nothing outside its own injection is carrying no redundancy.
    """
    names = [b[0] for b in BENCHES]
    print(f"{'injection':<34}" + "".join(f"{n[:11]:<12}" for n in names))
    rows = []
    for inj in INJECTIONS:
        original = open(inj["file"]).read()
        if inj["frm"] not in original:
            print(f"{inj['name'][:33]:<34}(target absent -- vacuous)")
            continue
        row = []
        try:
            open(inj["file"], "w").write(
                original.replace(inj["frm"], inj["to"], 1))
            for name, local, vendor, checker in BENCHES:
                ok, _ = run(name, local, vendor, checker, False)
                row.append("-" if ok is None else ("CAUGHT" if ok is False
                                                   else "."))
        finally:
            open(inj["file"], "w").write(original)
        print(f"{inj['name'][:33]:<34}" +
              "".join(f"{c:<12}" for c in row))
        # Whether the fault's OWN benches could run is the question. A dot from
        # a bench that has nothing to do with this fault is not evidence of a
        # gap -- it is a bench correctly minding its own business.
        own_ran = any(row[i] != "-" for i, n in enumerate(names)
                      if n in inj["benches"])
        rows.append((inj["name"], row, own_ran))

    print()
    print("  CAUGHT = the bench failed, which is what an injection should do")
    print("  .      = the bench ran and passed anyway")
    print("  -      = the bench could not be built")
    print()
    singles = [n for n, r, _ in rows if sum(1 for c in r if c == "CAUGHT") == 1]
    # "Caught by nothing" splits two ways, and conflating them is the same
    # error this suite has now made four times in four places. A fault that ran
    # past live benches and survived is a real gap. A fault whose benches could
    # not be built has not been missed -- it has not been tested.
    zeros = [n for n, r, own in rows
             if not any(c == "CAUGHT" for c in r) and own]
    untested = [n for n, r, own in rows
                if not any(c == "CAUGHT" for c in r) and not own]
    if zeros:
        print(f"caught by nothing, with live benches that could have: "
              f"{', '.join(zeros)}")
    if untested:
        print(f"untested -- every bench for these could not be built: "
              f"{', '.join(untested)}")
    if singles:
        print(f"caught by exactly one bench (a single point of failure in the "
              f"suite): {', '.join(singles)}")
    for i, name in enumerate(names):
        if rows and not any(r[i] == "CAUGHT" for _, r, _o in rows):
            print(f"bench '{name}' caught none of these -- its own fault class "
                  f"may be untested, or it may be carrying no redundancy")
    if zeros:
        return 1
    return 2 if untested else 0


def full(verbose):
    """All four modes, one verdict.

    The distinction that matters in the summary is between a check that failed
    and a check that could not run. Three cycles of this suite were spent
    learning that they are not the same thing, in three different places: a
    skipped bench is not a passing one, an injection whose bench cannot build
    has not been missed, and a mutation that changes nothing has not been
    survived.
    """
    results = {}
    print("=" * 70)
    print("1/5  benches")
    print("=" * 70)
    results["benches"] = main_benches(verbose)
    print()
    print("=" * 70)
    print("2/5  checker audit -- are the wrappers as strict as the benches?")
    print("=" * 70)
    results["audit"] = audit(verbose)
    print()
    print("=" * 70)
    print("3/5  self-test -- can an injected fault be caught?")
    print("=" * 70)
    results["selftest"] = selftest(verbose)
    print()
    print("=" * 70)
    print("4/5  coverage matrix -- what catches what?")
    print("=" * 70)
    results["matrix"] = matrix(verbose)
    print()
    print("=" * 70)
    print("5/5  facts -- does every stated number still come out of a run?")
    print("=" * 70)
    results["facts"] = facts(verbose)

    print()
    print("=" * 70)
    names = {0: "pass", 1: "FAIL", 2: "incomplete"}
    for k, v in results.items():
        print(f"  {k:<10} {names.get(v, v)}")
    if any(v == 1 for v in results.values()):
        print("REGRESSION FAIL")
        return 1
    if any(v == 2 for v in results.values()):
        print("REGRESSION INCOMPLETE -- everything that could run, passed")
        return 2
    print("REGRESSION PASS")
    return 0


def main_benches(verbose):
    return _run_benches(verbose)


def main(argv):
    verbose = "-v" in argv
    if "--full" in argv:
        return full(verbose)
    if "--facts" in argv:
        return facts(verbose)
    if "--seeds" in argv:
        return seeds(verbose)
    if "--audit" in argv:
        return audit(verbose)
    if "--matrix" in argv:
        return matrix(verbose)
    if "--selftest" in argv:
        return selftest(verbose)
    return _run_benches(verbose)


def _run_benches(verbose):
    print(f"vendor sources: {HDL}"
          f"{'' if os.path.isdir(HDL) else '   [NOT PRESENT]'}")
    results = []
    for name, local, vendor, checker in BENCHES:
        ok, msg = run(name, local, vendor, checker, verbose)
        mark = "PASS" if ok else ("SKIP" if ok is None else "FAIL")
        print(f"  [{mark}] {name:<14} {msg}")
        results.append(ok)
    print()
    failed = [r for r in results if r is False]
    skipped = [r for r in results if r is None]
    if failed:
        print(f"SIMULATION FAIL -- {len(failed)} of {len(results)}")
        return 1
    if skipped:
        print(f"SIMULATION INCOMPLETE -- {len(skipped)} could not be built")
        return 2
    print(f"SIMULATION PASS -- {len(results)} of {len(results)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
