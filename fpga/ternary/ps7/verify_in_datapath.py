#!/usr/bin/env python3
"""verify_in_datapath -- check the correlator's silicon output, bit for bit,
against a software model, using samples that came through the vendor datapath.

Why this exists. `ATSPEED.md` records 256/256 bit-exact agreement at 8 and 63
taps, but those samples were pushed straight into the correlator. Inside ADI's
receive path the input is whatever the vendor's capture, frame delineation and
channel logic deliver, and a snapshot of a free-running stream read over AXI is
a number that can only be admired, not checked.

So the hardware captures deterministically: arming resets the correlator, records
exactly 128 input samples and 128 outputs, and freezes. This script reads both
arrays and re-derives every output from the inputs.

The model is written from `tern_corr_pn_tree.v` rather than from intent:

  * `xr` is a 63-deep shift register of **signed 16-bit** values, advanced only
    on `s_valid`, cleared to zero by reset.
  * each tap contributes `+xr[i]`, `-xr[i]` or nothing, for tap codes 2'b01,
    2'b10 and anything else respectively.
  * `m_data <= corr` is registered, and `corr` is combinational over the shift
    register **before** the current sample enters it -- non-blocking assignment
    in the same always block. So the value emitted alongside the j-th valid
    sample is the correlation over samples j-1 .. j-63, and the first is zero.

That last point is the one worth stating explicitly, because it is exactly the
off-by-one that `FIRST_LOAD.md` records getting wrong once already.

Usage:
    ./verify_in_datapath.py captured.txt

where captured.txt holds N input words then N output words, one hex value per
line, as read from 0x40010400.. and 0x40010800.. on the board. N is 128: the
first 64 warm the 63-deep shift register, and every output in the second half
therefore has a full window, which is what lets a 63-periodic input show its
matched-filter peak at any phase.
"""

import sys

N = 63          # taps
W = 16          # sample width
ACC = 24        # accumulator width


def taps():
    """tp[a] from ps7_ad9361_axi.v: (a[0] ^ a[2] ^ a[4]) ? 2'b01 : 2'b10."""
    out = []
    for a in range(N):
        parity = (a & 1) ^ ((a >> 2) & 1) ^ ((a >> 4) & 1)
        out.append(+1 if parity else -1)
    return out


def signed(value, bits):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def model(samples):
    """Return the output the RTL must produce for this input sequence."""
    tp = taps()
    xr = [0] * N
    out = []
    for s in samples:
        # corr is computed from xr as it stands, then the sample shifts in
        corr = sum(tp[i] * xr[i] for i in range(N))
        out.append(signed(corr, ACC))
        xr = [signed(s, W)] + xr[:-1]
    return out


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().split("\n\n")[-1])
        return 2
    words = [int(w, 16) for w in open(argv[1]).read().split() if w.strip()]
    if len(words) % 2:
        print(f"expected an even count (half in, half out), got {len(words)}")
        return 2
    n = len(words) // 2
    ins, outs = words[:n], [signed(w, ACC) for w in words[n:]]

    # Outputs before index N depend on samples from before the capture window.
    # That was harmless while the capture began with the correlator in reset, but
    # a frame-aligned start deliberately begins after the reset has lifted, so
    # the shift register is already warm and out[0] is not zero. Only outputs
    # from index N onward are determined by the captured inputs alone; checking
    # the earlier ones against a cleared-register model would be comparing
    # against data that was never recorded.
    tp = taps()
    warm = n > N and any(outs[:1]) is not None and outs[0] != 0
    first = N if warm else 0
    if warm:
        expected = [None] * N + [
            signed(sum(tp[i] * signed(ins[j - 1 - i], W) for i in range(N)), ACC)
            for j in range(N, n)]
    else:
        expected = model(ins)
    mismatches = [(j, expected[j], outs[j]) for j in range(first, n)
                  if expected[j] != outs[j]]

    print(f"input samples  : {len(ins)}")
    nz = sum(1 for s in ins if s)
    print(f"  non-zero     : {nz}")
    print(f"  distinct     : {len(set(ins))}")
    if nz == 0:
        print("  ALL ZERO -- nothing was captured; the comparison below is vacuous")
    print(f"first eight in : {' '.join('0x%04X' % s for s in ins[:8])}")
    print(f"first eight out: {' '.join('%d' % o for o in outs[:8])}")
    print()
    checked = n - first
    peak = max(outs[first:], key=abs)
    if not mismatches:
        print(f"{checked}/{checked} bit-exact -- silicon matches the model on "
              f"every fully-determined output")
        if warm:
            print(f"  outputs 0..{N-1} skipped: the shift register was already"
                  f" warm at capture start (out[0] = {outs[0]}), so they depend"
                  f" on samples that were never recorded")
        print(f"  largest magnitude: {peak}")
        if abs(peak) == N * 2047:
            print(f"  that is exactly {N} x 2047 -- the matched-filter peak,"
                  f" the accumulator's true maximum")
        return 0

    print(f"MISMATCH on {len(mismatches)} of {n}")
    for j, e, g in mismatches[:8]:
        print(f"  [{j:2d}] model {e:>9}   silicon {g:>9}   diff {g - e}")

    # A constant lag is the likeliest single cause, and saying which lag it is
    # turns a failure into a finding. Try the neighbouring alignments.
    for lag in (-2, -1, 1, 2):
        a = expected[max(0, lag):n + min(0, lag)]
        b = outs[max(0, -lag):n + min(0, -lag)]
        if a and a == b:
            print(f"  but the sequences agree exactly at a lag of {lag}"
                  f" -- the model's pipeline depth is off by {lag}, not the RTL")
            break
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
