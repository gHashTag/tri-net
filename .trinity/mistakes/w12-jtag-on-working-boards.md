# MISTAKE: JTAG connection to working boards

## What happened
Connected JTAG (openOCD) to a working board. Loaded U-Boot via JTAG. U-Boot executed `clear_reset_cause` which writes 0x00400000 to RESET_REASON (0xF8000258), clearing the POR bit. After this, FSBL parks on every subsequent boot from QSPI.

## Impact
Board can only boot from SD card after this. QSPI boot permanently broken until true POR.

## Rule
NEVER connect JTAG to a working P201Mini unless you intend to debug.
If you must use JTAG, DO NOT load U-Boot or execute any code that calls clear_reset_cause.
