#!/usr/bin/env python3
"""Convert a Xilinx .bit into the raw form the Zynq FPGA manager consumes.

The open flow (xc7frames2bit) emits a .bit: a small tagged header followed by
the configuration data. `/sys/class/fpga_manager/fpga0/firmware` wants the data
without that header. The remaining question is byte order, and it is the usual
reason a first load fails with an unhelpful message: bootgen's `-process_bitstream bin`
emits words byte-swapped relative to the .bit payload, and which form the driver
accepts depends on the kernel.

Rather than guess, this writes BOTH and reports which one carries the sync word
in the orientation the configuration engine expects. The loader then tries the
likely one first and falls back, so the answer comes from the board rather than
from an assumption.

Usage:  bit2bin.py design.bit [outdir]
Writes: design.bin       payload as it appears in the .bit
        design.swab.bin  same payload, byte-swapped within each 32-bit word
"""

import os
import struct
import sys

SYNC = 0xAA995566  # Xilinx 7-series configuration sync word


def parse_bit(data):
    """Return (metadata dict, payload bytes) from a .bit file."""
    pos = 0
    hdr_len = struct.unpack(">H", data[pos:pos + 2])[0]
    pos += 2 + hdr_len + 2  # skip the magic block and its 2-byte trailer
    meta = {}
    names = {b"a": "design", b"b": "part", b"c": "date", b"d": "time"}
    while pos < len(data):
        key = data[pos:pos + 1]
        pos += 1
        if key == b"e":
            (length,) = struct.unpack(">I", data[pos:pos + 4])
            pos += 4
            return meta, data[pos:pos + length]
        if key not in names:
            raise ValueError(f"unexpected field {key!r} at offset {pos - 1}")
        (slen,) = struct.unpack(">H", data[pos:pos + 2])
        pos += 2
        meta[names[key]] = data[pos:pos + slen].rstrip(b"\x00").decode("latin-1")
        pos += slen
    raise ValueError("no 'e' field: this does not look like a .bit")


def swab32(buf):
    """Reverse byte order within every 32-bit word."""
    if len(buf) % 4:
        buf = buf + b"\x00" * (4 - len(buf) % 4)
    out = bytearray(len(buf))
    out[0::4] = buf[3::4]
    out[1::4] = buf[2::4]
    out[2::4] = buf[1::4]
    out[3::4] = buf[0::4]
    return bytes(out)


def find_sync(buf, limit=4096):
    """Offset of the sync word in the first `limit` bytes, or -1."""
    needle = struct.pack(">I", SYNC)
    return buf.find(needle, 0, limit)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    src = argv[1]
    outdir = argv[2] if len(argv) > 2 else os.path.dirname(src) or "."
    base = os.path.splitext(os.path.basename(src))[0]

    meta, payload = parse_bit(open(src, "rb").read())
    print(f"design : {meta.get('design', '?')}")
    print(f"part   : {meta.get('part', '?')}")
    print(f"built  : {meta.get('date', '?')} {meta.get('time', '?')}")
    print(f"payload: {len(payload)} bytes")

    swapped = swab32(payload)
    plain_at, swab_at = find_sync(payload), find_sync(swapped)
    print(f"sync 0xAA995566: plain at {plain_at}, byte-swapped at {swab_at}")
    if plain_at >= 0:
        print("-> try design.bin first")
    elif swab_at >= 0:
        print("-> try design.swab.bin first")
    else:
        print("-> WARNING: sync word found in neither form; the payload may be")
        print("   compressed or this is not a 7-series configuration stream")

    for name, buf in ((f"{base}.bin", payload), (f"{base}.swab.bin", swapped)):
        path = os.path.join(outdir, name)
        with open(path, "wb") as fh:
            fh.write(buf)
        print(f"wrote {path} ({len(buf)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
