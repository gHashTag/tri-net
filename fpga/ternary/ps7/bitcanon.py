#!/usr/bin/env python3
"""bitcanon -- make a Xilinx .bit byte-reproducible by normalising its header.

Background. This project reported for months that the open flow
(yosys -> nextpnr-xilinx -> fasm2frames -> xc7frames2bit) "is not byte
reproducible at the final stage", and concluded that a SHA-256 seal on the
bitstream "currently attests to nothing".

Measured 2026-08-03, two runs of xc7frames2bit on an identical .frames input:

    differing bytes: 1
    offset 100 (1-indexed): '4' vs '8'

That byte is the seconds digit of field 'd' of the .bit header:

    field 'c' = 2026/08/02      (build date)
    field 'd' = 18:37:14        run A
    field 'd' = 18:37:18        run B

Everything else -- all 4 045 470 bytes of configuration payload, the part name,
the frame data, every bit that reaches the silicon -- is identical. SHA-256 of
the payload was the same on both runs:

    ad22ca18735dc6ccd649687082390565b0a8944804ceaaa72f44d8c5c9fd36c1

So the flow was never nondeterministic. The tool stamps the wall clock into a
metadata field, which is the single most common cause of an unreproducible
build in any toolchain, and the standard remedy applies: pin the timestamp.

Usage:
    bitcanon.py in.bit [-o out.bit] [--epoch YYYY/MM/DD,HH:MM:SS]
    bitcanon.py in.bit --payload-hash      # hash what reaches the silicon

Header format (Xilinx .bit, UG470 and the widely documented layout):
    2-byte big-endian length + that many bytes    (magic preamble)
    2-byte 0x0001
    'a' + 2-byte BE length + NUL-terminated design name
    'b' + 2-byte BE length + NUL-terminated part name
    'c' + 2-byte BE length + NUL-terminated date  "YYYY/MM/DD"
    'd' + 2-byte BE length + NUL-terminated time  "HH:MM:SS"
    'e' + 4-byte BE length + raw configuration payload
"""

import argparse
import hashlib
import struct
import sys

FIXED_NAME = "canonical;Generator=xc7frames2bit"
FIXED_DATE = "2000/01/01"
FIXED_TIME = "00:00:00"


def parse(buf):
    """Return (fields, payload_offset). fields maps key -> (start, end, value)."""
    p = 0
    n = struct.unpack(">H", buf[p:p + 2])[0]
    p += 2 + n
    p += 2                                    # the 0x0001 word
    fields = {}
    while p < len(buf):
        key = chr(buf[p])
        p += 1
        if key == "e":
            ln = struct.unpack(">I", buf[p:p + 4])[0]
            p += 4
            fields["e"] = (p, p + ln, None)
            return fields, p, ln
        ln = struct.unpack(">H", buf[p:p + 2])[0]
        p += 2
        val = buf[p:p + ln].rstrip(b"\0").decode("ascii", "replace")
        fields[key] = (p, p + ln, val)
        p += ln
    raise ValueError("no 'e' payload field found -- not a .bit file?")


def canon(buf, date, time_):
    """Normalise the three header fields that vary between builds: the design
    name (which carries the input FILENAME, so it differs whenever the caller
    names its intermediate file differently) and the build date and time."""
    fields, pay_off, pay_len = parse(buf)
    out = bytearray(buf)
    for key, new in (("a", FIXED_NAME), ("c", date), ("d", time_)):
        if key not in fields:
            continue
        start, end, old = fields[key]
        room = end - start
        blob = new.encode("ascii")[: room - 1].ljust(room - 1, b" ") + b"\0"
        out[start:end] = blob
    return bytes(out), fields, pay_off, pay_len


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bit")
    ap.add_argument("-o", "--output")
    ap.add_argument("--epoch", default=f"{FIXED_DATE},{FIXED_TIME}",
                    help="YYYY/MM/DD,HH:MM:SS to stamp instead of the wall clock")
    ap.add_argument("--payload-hash", action="store_true",
                    help="print SHA-256 of the configuration payload only")
    a = ap.parse_args()

    buf = open(a.bit, "rb").read()
    date, _, time_ = a.epoch.partition(",")
    out, fields, pay_off, pay_len = canon(buf, date, time_ or FIXED_TIME)

    if a.payload_hash:
        h = hashlib.sha256(buf[pay_off:pay_off + pay_len]).hexdigest()
        print(f"payload_bytes={pay_len}")
        print(f"payload_sha256={h}")
        print(f"design={fields.get('a', (0, 0, '?'))[2]}")
        print(f"part={fields.get('b', (0, 0, '?'))[2]}")
        print(f"built={fields.get('c', (0, 0, '?'))[2]} {fields.get('d', (0, 0, '?'))[2]}")
        return 0

    dst = a.output or (a.bit + ".canon")
    open(dst, "wb").write(out)
    print(f"wrote {dst} ({len(out)} bytes)")
    print(f"file_sha256={hashlib.sha256(out).hexdigest()}")
    print(f"payload_sha256={hashlib.sha256(buf[pay_off:pay_off + pay_len]).hexdigest()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
