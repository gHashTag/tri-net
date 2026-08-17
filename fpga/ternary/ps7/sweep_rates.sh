LOG=/mnt/jffs2/sweep.log
say() { echo "$*" >> $LOG; }
rd() { busybox devmem $1 32 2>/dev/null || echo BUSERROR; }
killall iio_readdev iio_writedev 2>/dev/null; killall iiod 2>/dev/null; sleep 2
for d in 79020000.cf-ad9361-lpc 79024000.cf-ad9361-dds-core-lpc; do
  drv=$(basename $(readlink -f /sys/bus/platform/devices/$d/driver 2>/dev/null) 2>/dev/null)
  echo $d > /sys/bus/platform/drivers/$drv/unbind 2>/dev/null
done
for d in 7c400000.dma 7c420000.dma; do echo $d > /sys/bus/platform/drivers/dma-axi-dmac/unbind 2>/dev/null; done
ip link set eth0 down 2>/dev/null
echo e000b000.ethernet > /sys/bus/platform/drivers/macb/unbind 2>/dev/null
sleep 2
busybox devmem 0xF8000008 32 0xDF0D
busybox devmem 0xF8000170 32 0x00101400
busybox devmem 0xF8000240 32 0x00000000
cp /tmp/rate.swab.bin /lib/firmware/
echo rate.swab.bin > /sys/class/fpga_manager/fpga0/firmware
sleep 5
say "state: $(cat /sys/class/fpga_manager/fpga0/state)  bridge: $(rd 0x40010000)"
busybox devmem 0x40000040 32 0x00000003 2>/dev/null
busybox devmem 0x40000400 32 0x00000051 2>/dev/null
busybox devmem 0x40010028 32 0x0000000A 2>/dev/null
say ""
say "SWEEP: FPGA1 divisor -> measured lclk cycles per 2^20 of the 50 MHz clk"
say "  ratio x 50 MHz / 1048576 = lclk MHz; lclk is FCLK1/2"
for DIV in 40 32 20 16 12 10 8; do
  CTL=$(( 0x00100000 | (DIV << 8) ))
  busybox devmem 0xF8000180 32 $CTL 2>/dev/null
  sleep 2
  R1=$(rd 0x40010030)
  busybox devmem 0x40010020 32 0x00000000 2>/dev/null; sleep 1
  busybox devmem 0x40010020 32 0x00000001 2>/dev/null; sleep 2
  ST=$(rd 0x40010024)
  say "DIV $DIV  ctl $CTL  rate $R1  capture $ST"
  i=0; while [ $i -lt 128 ]; do say "$(rd $(( 0x40010400 + i * 4 )))"; i=$(( i + 1 )); done
  i=0; while [ $i -lt 128 ]; do say "$(rd $(( 0x40010800 + i * 4 )))"; i=$(( i + 1 )); done
  say "ENDDIV"
done
say ALLDONE
sync; sleep 2; reboot
