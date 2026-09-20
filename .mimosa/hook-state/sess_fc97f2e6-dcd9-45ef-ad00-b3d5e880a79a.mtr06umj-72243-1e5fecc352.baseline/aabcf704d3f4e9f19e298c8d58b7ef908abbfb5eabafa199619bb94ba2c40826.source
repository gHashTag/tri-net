#!/usr/bin/env python3
"""Bytes -> BPSK I/Q sample buffer for the AD9361 TX DMA.

Digital loopback is sample-synchronous (no carrier, no clock offset), so BPSK
needs no recovery loops: sign of I at the symbol midpoint IS the bit. Barker-13
preamble locates the frame in the capture; the payload is a REAL VSTREAM mesh
fragment -- the exact wire format the video bridge sends -- so this doubles as
the first test of mesh bytes over the radio silicon.
"""
import struct, sys

SPS = 8               # samples per symbol
AMP = 0x4000          # 16-bit domain; RX sees the 12-bit-aligned version
BARKER = [1,1,1,1,1,-1,-1,1,1,-1,1,-1,1]

# A real VSTREAM data fragment: [8][seq_lo][seq_hi][idx][count] + 70B payload.
frag = bytes([8, 0x2A, 0x00, 0, 1]) + bytes((i*31+7) & 0xFF for i in range(70))
open("frag_sent.bin","wb").write(frag)

bits = []
for byte in frag:
    for k in range(8):
        bits.append((byte >> (7-k)) & 1)

symbols = BARKER + [1 if b else -1 for b in bits]
iq = bytearray()
for s in symbols:
    for _ in range(SPS):
        iq += struct.pack("<hh", s*AMP, 0)
# pad with silence so the cyclic buffer has a clear gap between repeats
for _ in range(40*SPS):
    iq += struct.pack("<hh", 0, 0)
open("bpsk_tx.bin","wb").write(iq)
print(f"frag {len(frag)}B -> {len(symbols)} symbols -> {len(iq)//4} samples ({len(iq)}B)")
