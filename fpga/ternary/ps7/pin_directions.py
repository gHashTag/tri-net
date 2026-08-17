#!/usr/bin/env python3
"""pin_directions -- classify every I/O pin in a bitstream as input, output or
unused, by reading the configuration rather than guessing from drive strength.

Why this matters here. `PINOUT.md` records that the place-and-route harness
picked thirty pins arbitrarily and that **all thirty collide with pins the
vendor design drives**, sixteen of them as outputs. Loading that design would
have driven signals onto pins wired to the AD9361. Knowing which pins are used
was enough to refuse; knowing which are *inputs* is what is needed to use any of
them safely.

The earlier attempt classified a tile as an output if it carried `DRIVE` or
`SLEW` features. That called all 78 configured tiles outputs, which cannot be
right -- the receive bus must be inputs. Those features are evidently emitted
for configured IOBs regardless of direction.

The feature that does distinguish them is `IN_ONLY`, and it is not a single bit
but a signature: four bits that must be set and fourteen that must be clear, per
site. A signature is much harder to match by accident than a lone bit, which is
worth something when the consequence of being wrong is driving a pin against
another driver.

Classification is deliberately three-way:

    IN_ONLY matches                  -> input
    otherwise, drive features match  -> output
    otherwise, any bit set in range  -> configured, direction unresolved
    otherwise                        -> unused

A two-way test cannot separate "output" from "unused", and that is exactly how
"unused" collapsed into "output" before.

Usage:
    ./pin_directions.py vendor.frm            classify and summarise
    ./pin_directions.py vendor.frm --pins     also list pin names per class
"""

import csv
import json
import os
import re
import sys

DB = os.environ.get(
    "PRJXRAY_DB",
    "/nix/store/j1nil74746ph2cywd0zk7v49x3x94d87-source/zynq7")
PART = os.environ.get("PRJXRAY_PART", "xc7z020clg400-1")
DEVICE = os.environ.get("PRJXRAY_DEVICE", "xc7z020")


def load_frames(path):
    """Read bitread's -o output: '.frame 0xADDR' then 101 words of hex."""
    frames = {}
    addr = None
    words = []
    for line in open(path):
        line = line.strip()
        if line.startswith(".frame"):
            if addr is not None:
                frames[addr] = words
            addr = int(line.split()[1], 16)
            words = []
        elif line:
            words.extend(int(w, 16) for w in line.split())
    if addr is not None:
        frames[addr] = words
    return frames


def load_segbits(tile_type):
    """feature -> [(frame_offset, bit_index, must_be_set), ...]"""
    path = os.path.join(DB, f"segbits_{tile_type.lower()}.db")
    if not os.path.exists(path):
        return {}
    out = {}
    for line in open(path):
        parts = line.split()
        if len(parts) < 2:
            continue
        name, bits = parts[0], parts[1:]
        entries = []
        for b in bits:
            neg = b.startswith("!")
            if neg:
                b = b[1:]
            m = re.match(r"^(\d+)_(\d+)$", b)
            if not m:
                entries = None
                break
            entries.append((int(m.group(1)), int(m.group(2)), not neg))
        if entries:
            out[name] = entries
    return out


def bit_set(frames, base, offset, frame_off, bit_index):
    words = frames.get(base + frame_off)
    if words is None:
        return None
    w = offset + bit_index // 32
    if w >= len(words):
        return None
    return bool(words[w] & (1 << (bit_index % 32)))


def matches(frames, base, offset, entries):
    """A signature matches only if every bit agrees. Unknown bits fail it.

    A signature made entirely of must-be-clear bits matches an all-zero region,
    which means it matches every unused tile. That is how a first run reported
    121 outputs on a device with 78 configured tiles. So a match additionally
    requires at least one bit that must be *set*: evidence, not the absence of
    evidence.
    """
    if not any(want for _, _, want in entries):
        return False
    for frame_off, bit_index, want in entries:
        got = bit_set(frames, base, offset, frame_off, bit_index)
        if got is None or got != want:
            return False
    return True


def site_used(frames, base, offset, sb, ttype, site):
    """Is *this site* configured, as opposed to its tile?

    Asking per tile treats both halves of a used tile as candidates even when
    only one is really in use, which is what left 87 sites unresolved. Every
    feature belonging to a site names bit positions that only that site owns, so
    the union of their must-be-set positions is a site-local mask.
    """
    prefix = f"{ttype}.{site}."
    for name, entries in sb.items():
        if not name.startswith(prefix):
            continue
        # STEPDOWN is a bank-level property written into every site of a bank
        # running at a low VCCO, used or not. Counting it as evidence of use
        # made 75 empty sites look configured -- every one of them matched
        # STEPDOWN and nothing else.
        if name.endswith(".STEPDOWN"):
            continue
        for frame_off, bit_index, want in entries:
            if want and bit_set(frames, base, offset, frame_off, bit_index):
                return True
    return False


def any_bit_set(frames, base, offset, words_count, frames_count):
    for f in range(frames_count):
        words = frames.get(base + f)
        if not words:
            continue
        for w in range(offset, min(offset + words_count, len(words))):
            if words[w]:
                return True
    return False


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().split("\n\n")[-1])
        return 2
    frames = load_frames(argv[1])
    show_pins = "--pins" in argv
    print(f"frames read      : {len(frames)}")

    grid = json.load(open(os.path.join(DB, DEVICE, "tilegrid.json")))
    segbits = {t: load_segbits(t) for t in
               ("LIOB33", "RIOB33", "LIOB33_SING", "RIOB33_SING")}

    # tile+site -> package pin.
    # package_pins.csv names sites absolutely (IOB_X1Y62) while segbits names
    # them relative to the tile (IOB_Y0, IOB_Y1). The join is by rank, not by
    # string -- but the rank runs DOWNWARD: IOB_Y1 is the lower absolute Y.
    #
    # That was established, not assumed. A design constraining rx_clk_in to P19
    # (IOB_X1Y73, the lower of its tile's two) emits IN_ONLY on IOB_Y1 in the
    # FASM. Twelve of the fourteen pins could not have shown this, because they
    # occupy both halves of six tiles and the pin set is identical either way;
    # only the two tiles with a single site in use reveal it.
    pins = {}
    by_tile = {}
    pp = os.path.join(DB, PART, "package_pins.csv")
    if os.path.exists(pp):
        for row in csv.DictReader(open(pp)):
            site = row.get("site") or ""
            m = re.search(r"Y(\d+)$", site)
            if site.startswith("IOB_") and m:
                by_tile.setdefault(row["tile"], []).append(
                    (int(m.group(1)), row["pin"], row.get("pin_function", "")))
    for tile, entries in by_tile.items():
        for rank, (_, pin, func) in enumerate(sorted(entries, reverse=True)):
            pins[(tile, f"IOB_Y{rank}")] = (pin, func)

    # Pull configuration, reported alongside direction. ADI's own constraint
    # file gives exactly one signal a pull-up -- `spi_csn` -- because a floating
    # chip select invites stray transactions. If the vendor design does the
    # same, a pull-up on an output is a strong single-pin signature for chip
    # select, and a far cheaper way to find it than tracing routing.
    #
    # UNTESTED against the vendor image: that bitstream was held only in /tmp
    # and has been lost, and the board is unreachable to re-read it. What
    # follows is verified to run and to report correctly on our own designs;
    # the hypothesis about spi_csn is not yet evidence.
    pulls = {}
    classes = {"input": [], "output": [], "unresolved": [], "unused": []}
    for name, tile in sorted(grid.items()):
        ttype = tile.get("type", "")
        if not ttype.startswith(("LIOB33", "RIOB33")):
            continue
        bits = (tile.get("bits") or {}).get("CLB_IO_CLK")
        if not bits:
            continue
        base = int(bits["baseaddr"], 16)
        offset = bits["offset"]
        nframes = bits["frames"]
        nwords = bits["words"]
        sb = segbits.get(ttype, {})

        tile_used = any_bit_set(frames, base, offset, nwords, nframes)
        for site in ("IOB_Y0", "IOB_Y1"):
            used = tile_used and site_used(frames, base, offset, sb, ttype, site)
            in_only = [f for f in sb if f.startswith(f"{ttype}.{site}.")
                       and f.endswith(".IN_ONLY")]
            drive = [f for f in sb if f.startswith(f"{ttype}.{site}.")
                     and (".OUT" in f or ".DRIVE" in f or ".SLEW" in f)]
            key = f"{name}/{site}"
            hit = pins.get((name, site))
            label = key + (f"  {hit[0]:<4} {hit[1]}" if hit else "")
            for kind in ("PULLUP", "PULLDOWN", "KEEPER", "NONE"):
                f = f"{ttype}.{site}.PULLTYPE.{kind}"
                if f in sb and matches(frames, base, offset, sb[f]):
                    pulls.setdefault(kind, []).append(label)
                    break

            if used and any(matches(frames, base, offset, sb[f])
                            for f in in_only):
                classes["input"].append(label)
            elif used and any(matches(frames, base, offset, sb[f])
                              for f in drive):
                classes["output"].append(label)
            elif used:
                classes["unresolved"].append(label)
            else:
                classes["unused"].append(label)

    print(f"sites classified : {sum(len(v) for v in classes.values())}")
    for k in ("input", "output", "unresolved", "unused"):
        print(f"  {k:<11}: {len(classes[k])}")
    if pulls:
        print("pull configuration: " +
              ", ".join(f"{k} {len(v)}" for k, v in sorted(pulls.items())))
        for s_ in pulls.get("PULLUP", []):
            print(f"  PULL-UP: {s_}")
    if show_pins:
        for k in ("input", "output", "unresolved"):
            if classes[k]:
                print(f"\n{k}:")
                for s in classes[k]:
                    print(f"  {s}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
