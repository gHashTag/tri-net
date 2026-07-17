#!/usr/bin/env python3
"""RX capture -> bytes. Correlate Barker-13 at symbol rate, slice, compare."""
import struct, sys

SPS = 8
BARKER = [1,1,1,1,1,-1,-1,1,1,-1,1,-1,1]
raw = open(sys.argv[1] if len(sys.argv)>1 else "bpsk_rx.bin","rb").read()
n = len(raw)//4
I = [struct.unpack_from("<h", raw, 4*k)[0] for k in range(n)]
want = open("frag_sent.bin","rb").read()
nbits = len(want)*8

best, best_off = -1, 0
for off in range(0, n - (len(BARKER)+nbits)*SPS):
    c = sum(BARKER[j]*I[off + j*SPS + SPS//2] for j in range(len(BARKER)))
    if c > best:
        best, best_off = c, off
start = best_off + len(BARKER)*SPS
bits = [1 if I[start + j*SPS + SPS//2] > 0 else 0 for j in range(nbits)]
out = bytearray()
for k in range(0, nbits, 8):
    b = 0
    for j in range(8):
        b = (b<<1) | bits[k+j]
    out.append(b)
ok = bytes(out) == want
print(f"correlation peak {best} at sample {best_off}")
print(f"decoded {len(out)}B; byte-identical to the sent VSTREAM fragment: {'YES' if ok else 'NO'}")
if not ok:
    diff = sum(1 for a,b in zip(out,want) if a!=b)
    print(f"  differing bytes: {diff}/{len(want)}")
sys.exit(0 if ok else 1)
