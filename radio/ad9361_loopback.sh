#!/bin/sh
# AD9361 5.8 GHz radio-PHY bring-up + internal-loopback IQ self-test.
# Runs ON THE MINI (Puzhi P201Mini, Zynq-7020 + AD9361). tri-net#9.
#
# Tunes both LOs to 5.8 GHz, emits a complex DDS tone on TX1, enables the
# AD9361 internal DIGITAL loopback (TX->RX, no RF radiated), and captures RX IQ.
# Pull /tmp/rx.dat to a host and run analyze_tone.py to see the tone.
#
# Verified 2026-07-01: FFT peak at +0.999 MHz, 108.6 dB over noise floor.
set -e
PHY=/sys/bus/iio/devices/iio:device0          # ad9361-phy
DDS=/sys/bus/iio/devices/iio:device2          # cf-ad9361-dds-core-lpc (TX)
LO=${LO:-5800000000}                          # 5.8 GHz drone-mesh band
TONE=${TONE:-1000000}                          # 1 MHz baseband tone
N=${N:-65536}                                  # samples to capture

echo "$LO" > "$PHY/out_altvoltage0_RX_LO_frequency"
echo "$LO" > "$PHY/out_altvoltage1_TX_LO_frequency"

# Complex tone on TX1 (I leads Q by 90 deg) -> single sideband at +TONE.
echo "$TONE" > "$DDS/out_altvoltage0_TX1_I_F1_frequency"
echo "$TONE" > "$DDS/out_altvoltage2_TX1_Q_F1_frequency"
echo 90000   > "$DDS/out_altvoltage0_TX1_I_F1_phase"
echo 0       > "$DDS/out_altvoltage2_TX1_Q_F1_phase"
echo 0.25    > "$DDS/out_altvoltage0_TX1_I_F1_scale"
echo 0.25    > "$DDS/out_altvoltage2_TX1_Q_F1_scale"

# Internal digital loopback (0=off, 1=digital, 2=RF). Digital = fully on-chip.
mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
echo "${LOOPBACK:-1}" > /sys/kernel/debug/iio/iio:device0/loopback

echo "LO=$(cat "$PHY/out_altvoltage0_RX_LO_frequency") \
loopback=$(cat /sys/kernel/debug/iio/iio:device0/loopback) \
tone=$(cat "$DDS/out_altvoltage0_TX1_I_F1_frequency")Hz \
fs=$(cat "$PHY/in_voltage_sampling_frequency")"

iio_readdev -b "$N" -s "$N" cf-ad9361-lpc voltage0 voltage1 > /tmp/rx.dat 2>/dev/null
echo "captured $(wc -c < /tmp/rx.dat) bytes -> /tmp/rx.dat"
