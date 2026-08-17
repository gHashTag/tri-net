#!/usr/bin/env python3
"""Software reference for the 63-tap PN despreader, and its golden vectors.

Same purpose as corr_reference.py, one order of magnitude up: eight taps is a
primitive, 63 is the length the DSSS link actually despreads with. The
arithmetic is written the way the hardware does it -- a signed shift register of
the last N samples, sign-select against 2-bit ternary taps, and a signed
accumulator truncated to ACC bits -- so the fabric can be checked by equality
rather than by eye.

The code is the project's own m-sequence, taken from tern_pn_lfsr.v:
6-bit Fibonacci LFSR, primitive polynomial x^6 + x^5 + 1, feedback
lfsr[5] ^ lfsr[4], output lfsr[5], seed 0x3F, mapping 1 -> +1 and 0 -> -1.

  ./pn_reference.py ../ota/rx_on_raw.hex --golden pn_golden.txt
"""

import argparse
import sys

N = 63
W = 16
ACC = 24
SEED = 0x3F


def to_signed(value, bits):
    sign_bit = 1 << (bits - 1)
    return (value & (sign_bit - 1)) - (value & sign_bit)


def pn_taps(n=N, seed=SEED):
    """The length-63 m-sequence as ternary taps, +1 / -1, newest tap first."""
    lfsr = seed & 0x3F
    out = []
    for _ in range(n):
        out.append(+1 if (lfsr >> 5) & 1 else -1)
        fb = ((lfsr >> 5) & 1) ^ ((lfsr >> 4) & 1)
        lfsr = ((lfsr << 1) | fb) & 0x3F
    return out


def read_hex_samples(path):
    out = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            out.append(to_signed(int(line, 16), W))
    return out


def correlate(samples, taps):
    """One output per ingested sample. xr[0] is newest. Truncate to ACC bits."""
    shift = [0] * len(taps)
    mask = (1 << ACC) - 1
    for sample in samples:
        shift = [sample] + shift[:-1]
        acc = 0
        for x, w in zip(shift, taps):
            if w == +1:
                acc += x
            elif w == -1:
                acc -= x
        yield to_signed(acc & mask, ACC)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--golden")
    ap.add_argument("--taps", help="write the 63 tap codes, one per line, for the loader")
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args(argv)

    samples = read_hex_samples(a.capture)
    if a.limit:
        samples = samples[: a.limit]
    taps = pn_taps()

    vals = list(correlate(samples, taps))
    peak = max(abs(v) for v in vals) if vals else 0
    rms = (sum(v * v for v in vals) / len(vals)) ** 0.5 if vals else 0.0

    print(f"capture : {a.capture}")
    print(f"code    : PN63 m-sequence, x^6+x^5+1, seed 0x{SEED:02X}")
    print(f"taps    : {''.join('+' if t > 0 else '-' for t in taps)}")
    print(f"samples : {len(samples)}")
    print(f"peak|corr| : {peak}")
    print(f"rms|corr|  : {rms:.1f}")

    if a.golden:
        with open(a.golden, "w") as fh:
            for v in vals:
                fh.write(f"{v}\n")
        print(f"golden  : {a.golden} ({len(vals)} values)")

    if a.taps:
        # 2-bit codes as the hardware wants them: 01 -> +1, 10 -> -1
        with open(a.taps, "w") as fh:
            for t in taps:
                fh.write(f"{1 if t > 0 else 2}\n")
        print(f"taps    : {a.taps} ({len(taps)} codes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
