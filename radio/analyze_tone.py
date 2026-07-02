#!/usr/bin/env python3
"""FFT-analyze RX IQ captured by ad9361_loopback.sh. tri-net#9.

Reads interleaved int16 I/Q from /tmp/rx.dat (or argv[1]) and reports the
dominant tone frequency and its SNR. Usage: analyze_tone.py [rx.dat] [fs_Hz]
"""
import sys
import numpy as np

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/rx.dat"
fs = float(sys.argv[2]) if len(sys.argv) > 2 else 30.72e6

d = np.fromfile(path, dtype="<i2")
if d.size < 16:
    sys.exit(f"no/short data in {path}: {d.size} samples")

iq = d[0::2].astype(np.float32) + 1j * d[1::2].astype(np.float32)
n = 1 << int(np.floor(np.log2(iq.size)))
iq = iq[:n]

spec = np.fft.fftshift(np.fft.fft(iq * np.hanning(n)))
freq = np.fft.fftshift(np.fft.fftfreq(n, 1 / fs))
mag = 20 * np.log10(np.abs(spec) + 1e-9)
peak = int(np.argmax(mag))
snr = mag[peak] - np.median(mag)

print(f"samples   : {n}")
print(f"rx rms    : {np.sqrt(np.mean(np.abs(iq) ** 2)):.1f}")
print(f"peak tone : {freq[peak] / 1e6:+.3f} MHz")
print(f"snr       : {snr:.1f} dB over noise floor")
