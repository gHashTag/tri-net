## Goal

On the Mini (Zynq-7020 + AD9361), bring up 5.8GHz TX/RX and a 5.8GHz OFDM PHY (single-carrier fallback ready), then establish a bench-safe two-Mini link over SMA attenuators.

## Context

**HONEST STATUS (report v2.2):** highest-risk item on the whole track. Nothing here has ever run on hardware. No AD9361 SPI init, no libiio/no-OS driver bring-up, no RF calibration, no OFDM PHY, no single-carrier PHY exists on disk. Local `fpga/` docs cover ONLY the Xilinx 7-series LED/UART bring-up story — ZERO coverage of Zynq-7020, AD9361/AD9363 SDR, 5.8GHz, or any radio PHY. Everything below is greenfield.

**Board:** P201/P203 Mini (XC7Z020 dual Cortex-A9 + FPGA) + **AD9361** (70MHz–6GHz — required; AD9363 is officially capped at 3.8GHz and will NOT reach 5.8GHz), 1x GbE, boots ARM-Linux from SD. This is the flying MVP radio node (SDR + light weight). The AD9361 owns the RF front-end; the ARM PS runs the radio-socket/PHY glue that `trios-mesh` will later sit on.

**Why now:** the FPGA hardware is physically connected, which unblocks P0 first-flash and PS/ARM-Linux boot. Once `p0-mini-boot` confirms AD9361 enumerates over `libiio`/`iio` and GPS/PPS/10MHz lock, we can drive real RF.

**Bench-safety rule:** the two-Mini link is established over **SMA RF attenuators + RG316 cables, NOT over-air** (5.8GHz over-air needs external PA+LNA and raises regulatory/EMC concerns). Onboard Mini PA is only 10–15 dBm — insufficient for range; an external PA+LNA @5.8GHz is a procurement blocker for any real link budget but is NOT required for the attenuated over-cable bench link.

**PHY decision:** report says OFDM, but no PHY exists on hardware and OFDM-on-AD9361 is high risk. Keep a **single-carrier fallback** ready so the wk2-3 window holds even if OFDM slips. Single-carrier passing the loopback+attenuated-link gate is an acceptable exit for this issue; OFDM is the stretch target.

## Tasks

- [ ] Confirm the delivered Mini units ship the **AD9361** variant (not AD9363) and that it genuinely tunes to 5.8GHz — check firmware/band unlock before committing to the band.
- [ ] Bring up AD9361 on the Mini PS via `libiio` (or no-OS): SPI init, sample-rate/LO config, TX/RX enable at **5.8GHz**; confirm `iio_info` / `iio_readdev` see the device and stream samples.
- [ ] Internal RF loopback (TX→RX on one Mini through attenuator/coupler): capture samples, confirm carrier + constellation, run AD9361 RX/TX quadrature calibration.
- [ ] Implement a **single-carrier** modem baseline (QPSK/BPSK, known preamble, framing) end-to-end over the AD9361 sample interface — the fallback that must hold the window.
- [ ] Implement the **5.8GHz OFDM PHY** (subcarriers, CP, preamble/sync, per-frame equalization) as the primary target; keep single-carrier switchable if OFDM slips.
- [ ] Define the radio-socket interface the PHY exposes to the PS (raw AD9361 IQ vs a Linux net-facing framing) so `trios-mesh` (M1/M2) can bind to it later — document the decision.
- [ ] Wire two Minis via **SMA attenuators (~30–60 dB) + RG316 SMA-SMA cables** (bench, over-cable, NOT over-air); bring up TX on node A, RX on node B at 5.8GHz.
- [ ] Measure the attenuated over-cable link: lock/sync, EVM/BER vs attenuation, and raw PHY throughput; record results in `fpga/FLASH_HISTORY.md` / a new radio-PHY results doc.
- [ ] Record AD9361 config, band, sample rate, and measured link numbers into the `tri-net` skill references (`drone-mesh.md`) with `-sim` markers dropped only for what actually ran on hardware.

## Acceptance criteria

- [ ] `iio_info` on the Mini enumerates the AD9361; TX/RX configured and streaming at **5.8GHz**.
- [ ] Internal loopback shows a recovered, demodulated carrier (constellation locks; measurable EVM), post-calibration.
- [ ] At least one PHY (single-carrier acceptable; OFDM preferred) achieves frame lock and a measured BER/EVM curve on the **internal loopback**.
- [ ] Two-Mini **attenuated over-cable** link at 5.8GHz: node B recovers node A's frames, BER within threshold at the chosen attenuation, with a recorded throughput number. NO over-air testing.
- [ ] Results (band, sample rate, EVM/BER, throughput) committed to the repo, not just observed.

## Dependencies

- **Blocked by:** `p0-mini-boot` — *feat(fpga): boot ARM-Linux on Mini (Zynq-7020) + confirm AD9361/GPS/PPS enumerate* (AD9361 must enumerate and PS must boot before any RF).
- **Blocked by (procurement, external):** SMA attenuators (~30–60 dB) + RG316 SMA-SMA cables for the bench link. External PA+LNA @5.8GHz is required later for over-air range but NOT for this attenuated bench gate.
- **Feeds:** `trios-mesh` M1/M2 (radio-socket / IP-over-radio) and the P1 2-hop iperf3 milestone (M3).

---

phi^2 + phi^-2 = 3