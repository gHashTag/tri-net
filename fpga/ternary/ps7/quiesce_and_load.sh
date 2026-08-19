#!/bin/sh
# Stop every PL master, then load a bitstream. Runs ON THE BOARD, from the UART.
#
# load_and_verify.sh warns about the network and then walks straight into the
# DMA: writing the bitstream while a PL master is mid-transaction hangs the CPU
# on an unresponsive AXI slave, inside the write to $MGR/firmware, and only the
# watchdog ends it. FIRST_LOAD.md records that and says the teardown belongs in
# the loader. This is that teardown, in the order that document gives.
#
# Usage: ./quiesce_and_load.sh /tmp/ps7_probe.swab.bin

set -e
BIN="${1:-/tmp/ps7_probe.swab.bin}"
say() { echo "[quiesce] $*"; }

unbind_driver() {
    drv="/sys/bus/platform/drivers/$1"
    [ -d "$drv" ] || { say "$1: no such driver, skipping"; return 0; }
    for dev in "$drv"/*; do
        [ -e "$dev/driver" ] || continue
        name=$(basename "$dev")
        echo "$name" > "$drv/unbind" 2>/dev/null && say "$1: unbound $name" || say "$1: could not unbind $name"
    done
}

say "1/4 killing the sample streams"
killall iio_readdev iio_writedev iiod 2>/dev/null || true
sleep 1

say "2/4 unbinding the AD9361 cores"
unbind_driver cf_axi_adc
unbind_driver cf_axi_dds

say "3/4 unbinding the DMA engines"
unbind_driver dma-axi-dmac

say "4/4 taking PL Ethernet down -- the network dies here, the console does not"
ip link set eth0 down 2>/dev/null || true
unbind_driver macb
sleep 1

say "bus is quiet; loading $BIN"
sh /tmp/load_and_verify.sh "$BIN"
echo "QUIESCE_LOAD_RC=$?"
