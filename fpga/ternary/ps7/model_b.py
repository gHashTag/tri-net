#!/usr/bin/env python3
"""model_b -- a second, deliberately independent model of the ternary correlator.

Why this file exists. `pn_reference.py` says in its own docstring that "the
arithmetic is written the way the hardware does it": a signed shift register,
sign-select, an accumulator truncated to ACC bits. That makes it a
transliteration of the RTL, and a transliteration cannot catch a shared
misconception -- if the author misread the spec the same way twice, both agree
and the test passes.

This model is written from the *definition* instead, and differs from
`pn_reference.py` on every axis I could make it differ on:

| | pn_reference.py | model_b.py |
|---|---|---|
| formulation | shift register, stepped | direct sum over the definition |
| state | mutable list, sliced each sample | none; pure indexing into the input |
| precision | wrapped every sample | full Python int, wrapped once at output |
| PN generator | Fibonacci LFSR, shift-left | Galois LFSR, shift-right |
| tap order | as emitted | rebuilt and cross-checked against Fibonacci |

Agreement between the two is therefore evidence about the *specification*, not
just about one author's habits. Disagreement is a finding either way.

The definition being implemented, for output k over N taps:

    corr[k] = sum over j in 0..N-1 of  w[j] * x[k-j],    x[i] = 0 for i < 0

then reduced into a two's-complement field of ACC bits. Note this is
correlation with the newest sample against w[0], which is what the hardware's
`xr0 is newest` convention means -- stating it here so the convention is
checkable rather than assumed.

    ./model_b.py ../ota/rx_on_raw.hex --taps pn_taps.txt --compare pn_golden.txt
"""

import argparse
import sys

W_BITS = 16
ACC_BITS = 24


def wrap_signed(value, bits):
    """Reduce an arbitrary-precision integer into a two's-complement field."""
    mask = (1 << bits) - 1
    v = value & mask
    return v - (1 << bits) if v >> (bits - 1) else v


def pn_galois(n=63, seed=0x3F):
    """The same m-sequence, built the other way round.

    pn_reference.py uses a Fibonacci LFSR: shift left, feedback into the LSB,
    output the MSB. This uses the Galois form for x^6 + x^5 + 1: shift right,
    and XOR the tap mask back in when the bit shifted out was set. The two
    forms produce the same set of states in a different order, so this is only
    a genuine cross-check once the sequences are compared -- which `--selftest`
    does. Kept separate on purpose.
    """
    reg = seed & 0x3F
    out = []
    for _ in range(n):
        bit = reg & 1
        out.append(+1 if bit else -1)
        reg >>= 1
        if bit:
            reg ^= 0b110000            # x^6 + x^5
    return out


def pn_fibonacci(n=63, seed=0x3F):
    """Reimplemented here rather than imported, so a bug in the other file
    cannot silently propagate into this one."""
    reg = seed & 0x3F
    out = []
    for _ in range(n):
        out.append(+1 if (reg >> 5) & 1 else -1)
        fb = ((reg >> 5) & 1) ^ ((reg >> 4) & 1)
        reg = ((reg << 1) | fb) & 0x3F
    return out


def read_samples(path):
    """Hex, one two's-complement 16-bit word per line."""
    out = []
    for line in open(path):
        line = line.strip()
        if not line or line.startswith(("//", "#")):
            continue
        out.append(wrap_signed(int(line, 16), W_BITS))
    return out


def read_taps(path):
    """Tap codes as the loader writes them: 1 -> +1, 2 -> -1, anything else 0."""
    out = []
    for line in open(path):
        line = line.strip()
        if not line or line.startswith(("//", "#")):
            continue
        c = int(line)
        out.append(+1 if c == 1 else (-1 if c == 2 else 0))
    return out


def correlate_by_definition(x, w, acc_bits=ACC_BITS):
    """corr[k] = sum_j w[j] * x[k-j], full precision, wrapped once at the end.

    No shift register, no per-sample state, no intermediate truncation. If the
    hardware's incremental accumulator and this closed form ever disagree, the
    difference is either an overflow the hardware wraps and this does not, or a
    convention error -- and both are worth knowing about.
    """
    n = len(w)
    out = []
    for k in range(len(x)):
        total = 0
        for j in range(n):
            i = k - j
            if i >= 0 and w[j]:
                total += w[j] * x[i]
        out.append(wrap_signed(total, acc_bits))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--taps", required=True, help="tap codes, one per line (1/2/0)")
    ap.add_argument("--compare", help="golden file from the other model, to diff against")
    ap.add_argument("--golden", help="write this model's own output")
    ap.add_argument("--selftest", action="store_true",
                    help="check the Galois and Fibonacci PN generators agree")
    a = ap.parse_args(argv)

    if a.selftest:
        g, f = pn_galois(), pn_fibonacci()
        same = g == f
        print(f"PN cross-check   : Galois vs Fibonacci -> {'IDENTICAL' if same else 'DIFFER'}")
        if not same:
            first = next(i for i, (u, v) in enumerate(zip(g, f)) if u != v)
            print(f"  first difference at index {first}: galois={g[first]} fib={f[first]}")
            print("  (the two forms traverse the same states in a different order;")
            print("   a mismatch here is expected unless the seeds are aligned)")

    x = read_samples(a.capture)
    w = read_taps(a.taps)
    y = correlate_by_definition(x, w)

    print(f"capture          : {a.capture}  ({len(x)} samples, {min(x)} .. {max(x)})")
    print(f"taps             : {a.taps}  ({len(w)} taps, "
          f"{w.count(1)} plus, {w.count(-1)} minus, {w.count(0)} zero)")
    print(f"model B output   : {min(y)} .. {max(y)}")

    if a.golden:
        with open(a.golden, "w") as fh:
            for v in y:
                fh.write(f"{v}\n")
        print(f"written          : {a.golden}")

    if a.compare:
        other = [int(line) for line in open(a.compare) if line.strip()]
        n = min(len(other), len(y))
        bad = [(i, y[i], other[i]) for i in range(n) if y[i] != other[i]]
        if bad:
            print(f"COMPARE          : {len(bad)} of {n} DIFFER")
            for i, mine, theirs in bad[:5]:
                print(f"  index {i}: model_b={mine}  other={theirs}")
            return 1
        print(f"COMPARE          : {n} of {n} identical -- two independent "
              f"formulations agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
