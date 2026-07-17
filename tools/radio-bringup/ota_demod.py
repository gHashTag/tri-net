#!/usr/bin/env python3
"""Over-the-air FSK demod, carrier-offset tolerant.

Two boards have independent crystals, so their carriers differ (~0.5 MHz seen).
FSK sidesteps carrier recovery: what matters is WHICH of the marker/0/1 tones is
present, not its absolute frequency. With an I/Q capture the frequency is SIGNED,
so a common carrier offset shifts all three tones equally and preserves their
order. Per window we take the mean instantaneous frequency from I/Q phase
increments (cheap, no FFT) and cluster the active windows into marker<0<1.

STATUS: the demod is sound but SNR-starved without antennas. Measured on a real
.13->.12 OTA capture, the FSK tones sit at magnitude ~4 near the noise floor,
dominated by the receiver's DC/LO-leakage spike (~23) -- narrowband energy
detection over a long average still lifts the tone above noise (that is how the
LINK was confirmed), but per-0.3s-symbol demod needs the tone well above noise
and it is not. This is a hardware limit: antennas on the SMA ports (open now) or
the DMA/FPGA path for a strong modulated signal. Do NOT tune thresholds around
an SNR wall.
"""
import struct, math, sys

FS = float(sys.argv[2]) if len(sys.argv) > 2 else 2500000.0
WIN = 4096
raw = open(sys.argv[1] if len(sys.argv) > 1 else "ocap.bin", "rb").read()
n = len(raw) // 4

wins = []
for w0 in range(0, (n - 1) - WIN, WIN):
    sre = sim = 0.0; amp = 0.0
    pI = struct.unpack_from("<h", raw, 4 * w0)[0]
    pQ = struct.unpack_from("<h", raw, 4 * w0 + 2)[0]
    for k in range(w0 + 1, w0 + WIN):
        I = struct.unpack_from("<h", raw, 4 * k)[0]
        Q = struct.unpack_from("<h", raw, 4 * k + 2)[0]
        sre += I * pI + Q * pQ
        sim += Q * pI - I * pQ
        a = I * I + Q * Q
        if a > amp: amp = a
        pI, pQ = I, Q
    wins.append((math.sqrt(amp), math.atan2(sim, sre) * FS / (2 * math.pi)))

amps = sorted(w[0] for w in wins)
floor = amps[len(amps) // 2] * 1.5
active = [f for a, f in wins if a > floor]
print(f"windows={len(wins)} active={len(active)} floor~{floor:.0f}")
if active:
    lo, hi = min(active), max(active)
    t1, t2 = lo + (hi - lo) / 3, lo + 2 * (hi - lo) / 3
    seq = ["S" if a <= floor else ("M" if f < t1 else "0" if f < t2 else "1") for a, f in wins]
    runs = []
    for c in seq:
        if runs and runs[-1][0] == c: runs[-1][1] += 1
        else: runs.append([c, 1])
    runs = [r for r in runs if r[1] >= 3]
    bits = ""
    i = 0
    while i < len(runs) - 1:
        if runs[i][0] == "M" and runs[i + 1][0] in "01":
            bits += runs[i + 1][0]; i += 2
        else: i += 1
    print(f"bits: {bits}")
