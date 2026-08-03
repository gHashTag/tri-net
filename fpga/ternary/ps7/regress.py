#!/usr/bin/env python3
"""regress -- the standing check for the correlator-in-datapath work.

Three jobs, in the order they earn their keep:

1. **Disk.** Each build leaves roughly 80 MB behind -- a 47 MB netlist, a 23 MB
   FASM, a 4 MB bitstream -- and nothing was cleaning up. After thirty-odd
   cycles the volume filled and the whole loop stopped: not a build failure, a
   `no space left on device` that made it impossible to run any command at all,
   including the one that would have freed the space. `--clean` removes those
   intermediates; a plain run warns when headroom is short.

2. **The golden vector.** `golden/pn63_matched.txt` is a capture taken on
   silicon with the matched PN stimulus and a frame-aligned start. Two
   consecutive runs produced byte-identical files, which is what makes it usable
   as a fixture: any change that alters the arithmetic shows up immediately.

3. **A fresh capture**, compared against both the model and the golden vector.

Usage:
    ./regress.py                       check the golden vector and the disk
    ./regress.py --clean               also remove build intermediates
    ./regress.py fresh_capture.txt     compare a new capture against both
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN = os.path.join(HERE, "golden", "pn63_matched.txt")
VERIFY = os.path.join(HERE, "verify_in_datapath.py")

# Everything here is regenerable from committed sources. Nothing that took a
# measurement to obtain is listed -- capture logs are not intermediates.
INTERMEDIATES = [
    ("/tmp/a29", ("*.json", "*.fasm", "*.frm")),
    ("/tmp/a30", ("*.json", "*.fasm", "*.frm")),
    (os.path.join(HERE, "build"), ("*.bin",)),
]

MIN_FREE_GB = 6.0   # one build needs well under this; the margin is for the
                    # next few, because the failure mode is total rather than
                    # graceful


def free_gb(path="/"):
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize / (1 << 30)


def check_disk(clean):
    before = free_gb()
    print(f"free space: {before:.1f} GB")
    if clean:
        import glob
        removed = 0
        for d, patterns in INTERMEDIATES:
            for pat in patterns:
                for f in glob.glob(os.path.join(d, pat)):
                    try:
                        os.remove(f)
                        removed += 1
                    except OSError:
                        pass
        print(f"removed {removed} intermediate files, "
              f"free space now {free_gb():.1f} GB")
    elif before < MIN_FREE_GB:
        print(f"  WARNING: under {MIN_FREE_GB} GB. Run with --clean before the "
              f"next build.")
        print(f"  A full volume does not fail a build, it stops the loop: the "
              f"harness cannot even write a command's output.")
        return False
    return True


def run_verify(path, label):
    print(f"\n--- {label}: {os.path.basename(path)} ---")
    r = subprocess.run([sys.executable, VERIFY, path],
                       capture_output=True, text=True)
    print(r.stdout.rstrip())
    if r.stderr.strip():
        print(r.stderr.rstrip())
    return r.returncode == 0


def main(argv):
    clean = "--clean" in argv
    args = [a for a in argv[1:] if not a.startswith("--")]

    # Disk headroom is advice, not correctness. Folding it into the verdict
    # would make a housekeeping notice indistinguishable from an arithmetic
    # failure, which is the opposite of what a regression is for.
    roomy = check_disk(clean)
    ok = True

    if not os.path.exists(GOLDEN):
        print(f"\nMISSING: {GOLDEN}")
        return 1
    ok &= run_verify(GOLDEN, "golden vector")

    if args:
        fresh = args[0]
        ok &= run_verify(fresh, "fresh capture")
        a = open(GOLDEN).read().split()
        b = open(fresh).read().split()
        same = a == b
        print(f"\nfresh capture identical to the golden vector: {same}")
        if not same and len(a) == len(b):
            d = sum(1 for x, y in zip(a, b) if x != y)
            print(f"  {d} of {len(a)} words differ -- the arithmetic may still "
                  f"be correct (both are checked against the model above); what "
                  f"this shows is that the capture is no longer phase-aligned")
    print()
    print("REGRESSION PASS" if ok else "REGRESSION FAIL")
    if not roomy:
        print("(disk headroom is low -- advisory only, it did not affect the "
              "verdict above)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
