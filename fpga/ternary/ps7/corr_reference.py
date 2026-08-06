#!/usr/bin/env python3
"""Software reference for the ternary matched filter, and the golden vector generator.

The point of this file is comparison, not computation. It reproduces exactly what
`tern_corr8_stream` does in the fabric, sample by sample, so that the fabric's
answer can be checked against it bit for bit rather than statistically. A
correlation that is merely "close" is not evidence of anything.

  ./corr_reference.py ../ota/rx_on_raw.hex --code matched --golden golden.txt

The arithmetic is deliberately written the way the hardware does it: a signed
shift register of the last eight samples, sign-select against 2-bit ternary taps,
and a signed accumulator truncated to ACC bits. No floating point anywhere.
"""

import argparse
import sys

W = 16      # sample width, matches the ADC
ACC = 20    # accumulator width in tern_corr8_stream

# sign(cos(2*pi*k/8)) and sign(cos(2*pi*3*k/8)), the codes hard-coded in the
# project's own tern_ota_tb.v. +1 -> 0b01, -1 -> 0b10, 0 -> 0b00.
CODES = {
    "matched":    [+1, +1, 0, -1, -1, -1, 0, +1],
    "mismatched": [+1, -1, 0, +1, -1, +1, 0, -1],
}


def to_signed(value, bits):
    """Interpret an unsigned word as two's complement of the given width."""
    sign_bit = 1 << (bits - 1)
    return (value & (sign_bit - 1)) - (value & sign_bit)


def read_hex_samples(path):
    """Read the capture: one two's-complement hex word per line, ADC-native."""
    out = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            out.append(to_signed(int(line, 16), W))
    return out


def correlate(samples, taps):
    """Yield the correlator output for every ingested sample.

    Mirrors the hardware exactly: xr0 is the newest sample, xr7 the oldest, the
    shift happens on ingest, and the result appears one clock later. The value is
    truncated to ACC bits and re-interpreted as signed, which is what the
    hardware accumulator does when it overflows.
    """
    shift = [0] * 8
    for sample in samples:
        shift = [sample] + shift[:7]
        acc = 0
        for x, w in zip(shift, taps):
            if w == +1:
                acc += x
            elif w == -1:
                acc -= x
        yield to_signed(acc & ((1 << ACC) - 1), ACC)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture", help="hex capture, one signed 16-bit word per line")
    ap.add_argument("--code", choices=sorted(CODES), default="matched")
    ap.add_argument("--golden", help="write one expected correlation per line")
    ap.add_argument("--limit", type=int, default=0, help="use only the first N samples")
    args = ap.parse_args(argv)

    samples = read_hex_samples(args.capture)
    if args.limit:
        samples = samples[:args.limit]
    taps = CODES[args.code]

    values = list(correlate(samples, taps))
    peak = max(abs(v) for v in values) if values else 0
    rms = (sum(v * v for v in values) / len(values)) ** 0.5 if values else 0.0

    print(f"capture : {args.capture}")
    print(f"code    : {args.code}  {taps}")
    print(f"samples : {len(samples)}")
    print(f"peak|corr| : {peak}")
    print(f"rms|corr|  : {rms:.1f}")

    if args.golden:
        with open(args.golden, "w") as fh:
            for v in values:
                fh.write(f"{v}\n")
        print(f"golden  : {args.golden} ({len(values)} values)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
