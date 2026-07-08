# First Over-The-Air Data — Results (2026-07-08)

Status: PASS. First DATA ever transmitted over the air in this project:
one byte, board 1 -> boards 2 AND 3 simultaneously (broadcast), with the
receivers PHYSICALLY DISCONNECTED from Ethernet. No new binaries — pure
sysfs carrier keying (OOK) + RSSI detection, driven over UART consoles.

## Setup

- Board 1 (192.168.1.11, Ethernet gateway, internet verified via ping 8.8.8.8):
  TX LO 2.4 GHz, DDS 1 MHz tone, hardwaregain 0 dB, carrier keyed on/off
  per bit (2 s/bit) by writing TX1 I/Q scale 0.5 / 0.
- Boards 2 and 3 (no Ethernet cable, controlled via FT2232H ch-B consoles):
  RX LO 2.4 GHz, polled in_voltage0_rssi every 300 ms (70 samples).
- Decode on host: threshold 65 dB, 6.67 samples/bit, start = two
  consecutive ON samples (single-sample glitch tolerance needed on board 3).

## Link budget observed

| RX board | RSSI carrier off | RSSI carrier on | Margin  |
|----------|------------------|-----------------|---------|
| board 2  | 93.5 dB          | 44.5 dB         | ~49 dB  |
| board 3  | 87.4 dB          | 33.5 dB         | ~54 dB  |

(in_voltage0_rssi: lower = stronger. The historical E2E test recorded an
8.75 dB delta; antennas are clearly attached and the bench link is loud.)

## Result

Pattern sent: 10110010. Decoded on board 2: 10110010 (MATCH).
Decoded on board 3: 10110010 (MATCH). Both receivers heard the same
broadcast — the physical basis for the one-to-many mesh channel.

## What this proves / what it does not

Proves: full RF chain TX->air->RX on the exact boards that lost Ethernet;
consoles suffice to operate off-network nodes; broadcast reception works.
Does not: carry useful throughput (~0.5 bit/s). Internet-over-mesh needs
the BPSK ModemTransport (trios-mesh modem) glued to the IIO TX/RX buffers,
then meshd-over-radio + the proven M4 FETCH gateway path on board 1.

## Deployment constraint discovered

The rootfs is a ramdisk: every reboot wipes /tmp binaries. Off-network
boards can only be re-provisioned via brief Ethernet replug, SD sneakernet,
or (impractically, ~1 h per binary) serial base64. Plan deployments
accordingly; consider baking binaries onto the SD boot partition.
