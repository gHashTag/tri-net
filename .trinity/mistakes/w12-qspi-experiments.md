# MISTAKE: QSPI register experiments via Linux user-space

## What happened
Ran spidev binding + devmem on QSPI controller registers (0xE000D000) and SLCR QSPI reset (0xF8000230) on a WORKING board. Caused bus hang → soft reset → POR bit cleared → FSBL parks → board "dies".

## Impact
Lost a working board (board 2). Required 15+ hours of recovery work.

## Rule
NEVER touch QSPI controller registers from Linux user-space on P201Mini.
QSPI driver has a known bug (W25Q256 vs N25Q256A mismatch).
If you need QSPI access, use U-Boot `sf read/write` from serial console (not Linux).
