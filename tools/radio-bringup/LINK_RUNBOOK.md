# Cabled radio link runbook (.13 TX -> .12 RX or any pair)

Prereqs: two boards with FULL radio (phy + dds + lpc in IIO) and ensm=fdd.
After ANY cold power-on assume the radio is dead until a warm `reboot`
(CHIP_ID 0x0 = unpowered SPI; warm retry probes with rails settled).
OTA is FORBIDDEN: SMA TX (board A) -> 30-40 dB attenuator -> SMA RX (board B).

## 0. Per-board sanity (after every power event)
    cat /sys/bus/iio/devices/iio:device*/name        # need all: phy, dds, lpc
    cat /sys/bus/iio/devices/iio:device0/ensm_mode   # need: fdd (sleep = dead DMA;
                                                     #   this driver cannot leave sleep -> warm reboot)
    iio_readdev -b 1024 -s 1024 cf-ad9361-lpc voltage0 voltage1 > /tmp/n.bin
    # nonzero bytes = RX capture alive

## 1. Match the radios (both boards)
    # LO frequency attrs are RX_LO/TX_LO, NOT bare "frequency" (that silently
    # no-ops via iio_attr). Write sysfs directly to be sure:
    echo 2400000000 > /sys/bus/iio/devices/iio:device0/out_altvoltage0_RX_LO_frequency  # B
    echo 2400000000 > /sys/bus/iio/devices/iio:device0/out_altvoltage1_TX_LO_frequency  # A
    # verify: cat both back -- confirmed matched at 2.4 GHz on .12 and .13
    iio_attr -q -d ad9361-phy in_voltage_sampling_frequency 3000000
    iio_attr -q -c ad9361-phy voltage0 hardwaregain -30          # TX atten on A (start LOW)
    iio_attr -q -c ad9361-phy voltage0 gain_control_mode slow_attack  # on B

## 2. Send (board A) -- the same harness as loopback, minus the loopback
    while true; do cat /tmp/bpsk_tx4.bin; done | \
      iio_writedev -b 5224 cf-ad9361-dds-core-lpc voltage0 voltage1 voltage2 voltage3
    # KNOWN BLOCKER as of v0.26: buffer data does not reach the fabric TX on
    # this MathWorks image (mwipcore owns the path). Until that is solved,
    # step 2 falls back to the DDS tone (iio_attr altvoltage0 frequency/scale)
    # which DOES reach TX -- enough to verify the CABLE and levels end to end.

## 3. Receive (board B)
    iio_readdev -b 65536 -s 65536 cf-ad9361-lpc voltage0 voltage1 > /tmp/link_rx.bin
    # pull to the Mac; tone: expect a clean sinusoid at (TX LO - RX LO + tone) offset
    # bytes: python3 bpsk_demod.py link_rx.bin  (needs carrier/timing sync once
    # the path is RF instead of digital loopback -- digital-loopback demod
    # assumptions do NOT hold over the air/cable; extend demod first)

## Next levers for bytes over TX (in order)
1. debugfs direct_reg_access on iio:device2: read REG_CHAN_CNTRL_7 (0x0418 ch0,
   0x0458 ch1) DURING an active buffer. If DATA_SEL != 2 (DMA), poke it to 2 and
   toggle sync (0x0044). The driver may simply not be flipping the mux on this
   MathWorks core.
2. If DATA_SEL is correct and zeros persist, the fabric feeds TX from
   mwipcore@43c00000 -- drive it, or load the t27 BPSK core (specs/fpga/bpsk.t27)
   which owns the datapath explicitly.

## Power discipline (the decoded lottery)
- One board's reboot has taken the OTHER boards' power/network down (observed:
  rebooting .12 dropped .13 and .11 stayed dark) -- the shared supply browns out
  on inrush. SEPARATE SUPPLIES, or at minimum never expect survivors during any
  board's boot.
- Cold boot -> radio probably dead -> warm `reboot` -> radio probably back.
- /root is tmpfs: redeploy trios-meshd-video after every power event.
