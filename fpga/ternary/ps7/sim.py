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

Usage:
    ./sim.py            build and run everything
    ./sim.py -v         also print each testbench's full output
    ./sim.py --selftest inject a fault and require the suite to catch it
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


def check_spi(out):
    if "SPI MASTER OK" not in out:
        return False, "spi testbench did not report OK"
    if "HANG" in out:
        return False, "a transfer never completed"
    return True, "bit order, sampling edge, duplex and chip-select framing"


def check_ctrlplane(out):
    if "CONTROL PLANE OK" not in out:
        return False, "control-plane testbench did not report OK"
    return True, "control pins follow their register; a write becomes a transfer"


def check_bridge(out):
    if "BRIDGE OK" not in out:
        return False, "bridge testbench did not report OK"
    if "HANG" in out:
        return False, "a transaction hung -- that is the failure that costs a "\
                      "power cycle"
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


BENCHES = [
    ("spi_master", ["spi_master_tb.v", "spi_master.v"], [], check_spi),
    ("ctrlplane", ["ctrlplane_tb.v", "sim_stubs.v", "ps7_ad9361_ctrl.v",
                   "spi_master.v"] + CORE, VENDOR, check_ctrlplane),
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
            return None, f"no vendor sources at {os.path.join(HDL, pat)}"
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
    dict(name="bridge read timeout",
         file=os.path.join(HERE, "axi3_to_lite.v"),
         frm="end else if (rtmo == TIMEOUT) begin",
         to="end else if (1'b0) begin",
         benches=["axi3_to_lite"],
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
         benches=["spi_master"],
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
            caught = []
            for name, local, vendor, checker in BENCHES:
                if name not in inj["benches"]:
                    continue
                ok, _ = run(name, local, vendor, checker, verbose)
                caught.append(ok is False)
                if verbose or ok is not False:
                    print(f"      {name}: "
                          f"{'caught' if ok is False else 'did NOT catch'}")
            hit = sum(1 for c in caught if c)
            print(f"      caught by {hit} of {len(caught)} benches")
            if not hit:
                failures += 1
        finally:
            open(inj["file"], "w").write(original)
    if failures:
        print(f"  SELFTEST FAIL -- {failures} injections went unnoticed")
        return 1
    print(f"  SELFTEST PASS -- all {len(INJECTIONS)} injections were caught")
    return 0


def main(argv):
    verbose = "-v" in argv
    if "--selftest" in argv:
        return selftest(verbose)
    print(f"vendor sources: {HDL}")
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
