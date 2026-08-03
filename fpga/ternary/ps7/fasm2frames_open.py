#!/usr/bin/env python3
"""fasm2frames_open -- assemble a FASM file into Xilinx configuration frames.

Why this exists. nextpnr-xilinx emits FASM; turning that into a loadable
bitstream needs prjxray's `fasm2frames` and `xc7frames2bit`, and nixpkgs ships
no `prjxray` for aarch64-darwin. The prjxray *Python* library is installable
and does have the assembler, so the first half of the conversion needs no C++
build at all.

    ./fasm2frames_open.py <db_root>/zynq7 xc7z020clg400-1 design.fasm out.frames

Verified 2026-08-03 on the axi_ad9361 FASM produced by nextpnr:

    frames assembled : 5 936
    words per frame  : 101
    address range    : 0x00000900 .. 0x0042241D
    non-zero words   : 288 992

The second half -- frames to .bit -- is NOT done here, and the reason is worth
recording rather than glossed over.

A real xc7z020 bitstream produced by xc7frames2bit contains **10 008** frames in
one FDRI packet, while the prjxray database knows **7 802**. The difference is
padding: the 7-series configuration stream carries dummy frames at row and
block boundaries which are not database entries. So the mapping from frame
address to position in the FDRI payload is not "sort by address" -- it follows
the FAR progression with padding inserted, and getting it wrong produces a
bitstream that loads and then misbehaves, which is strictly worse than
producing nothing.

The safe way to derive that mapping is empirical rather than from the
specification: take a design whose .bit is already known good, assemble its
FASM with this script, and locate each frame's 101 words inside the template's
FDRI payload. That yields the address-to-index table directly, and it validates
itself -- every frame must be found exactly once.
"""

import sys
import warnings

warnings.filterwarnings("ignore")


def main(argv):
    if len(argv) < 4:
        print(__doc__.strip().split("\n\n")[2])
        return 2
    db_root, part, fasm_file = argv[1], argv[2], argv[3]
    out = argv[4] if len(argv) > 4 else None

    from prjxray import db as prjdb, fasm_assembler

    d = prjdb.Database(db_root, part)
    asm = fasm_assembler.FasmAssembler(d)

    # NOTE: set_feature_callback fires on EVERY feature, not only unknown ones
    # (fasm_assembler.add_fasm_line calls it unconditionally). Counting its
    # invocations and calling the result "missing" overstates the problem by
    # the entire size of the design. Genuinely unresolved features come back
    # through parse_fasm_filename's own list.
    seen = []
    asm.set_feature_callback(lambda f: seen.append(f))
    missing = asm.parse_fasm_filename(fasm_file) or []
    frames = asm.get_frames(sparse=True)

    words = len(next(iter(frames.values()))) if frames else 0
    nonzero = sum(1 for f in frames.values() for w in f if w)
    addrs = sorted(frames)

    print(f"frames assembled : {len(frames)}")
    print(f"words per frame  : {words}")
    if addrs:
        print(f"address range    : 0x{addrs[0]:08X} .. 0x{addrs[-1]:08X}")
    print(f"non-zero words   : {nonzero}")
    print(f"features processed: {len(seen)}")
    if missing:
        print(f"features with NO database entry: {len(missing)}")

    if out:
        with open(out, "w") as fh:
            for a in addrs:
                fh.write("0x%08X " % a)
                fh.write(",".join("0x%08X" % w for w in frames[a]))
                fh.write("\n")
        print(f"written          : {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
