# MISTAKE: Reading wrong PLL status register

## What happened
Read PLL lock status from 0xF800011C (returned 0x00000000) for 15+ attempts.
Correct register is 0xF800010C (returned 0x0000003F = all PLLs locked).

## Impact
Wasted hours diagnosing "PLL not locked" when PLLs were actually fine.
Made incorrect conclusions about FSBL failure.

## Rule
Zynq PLL lock status: 0xF800010C (bits: 0=ARM, 1=DDR, 2=IO).
NOT 0xF800011C (this is a different/unrelated register).
