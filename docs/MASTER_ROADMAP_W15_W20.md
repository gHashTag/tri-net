# Master Roadmap: W15-W20

**After:** W12 (boards), W13 (mesh), W14 (UX)
**Goal:** Full trios-chat product: text + photo + video over 3-channel mesh
**Anchor:** phi^2 + phi^-2 = 3

---

## Wave Summary

| Wave | Name | Deliverable | New Specs |
|------|------|-------------|-----------|
| W15 | Photo (Channel P) | 100KB JPEG in 3 sec | reed_solomon.t27, photo_transfer.t27 |
| W16 | Video (Channel V) | Live 720p 500kbps | ofdm_fft256.t27, video_stream.t27 |
| W17 | FPGA BPSK modem | BPSK TX/RX in PL Verilog | fpga_bpsk_modem.t27 |
| W18 | FPGA AES-256 | Hardware crypto line-rate | fpga_aes256.t27 |
| W19 | FPGA OFDM | 256-FFT in PL | fpga_ofdm.t27 |
| W20 | Integration | 3-channel demo, partner video | integration.t27 |

## Spec Pipeline (current: 77 specs)

```
W15: +2 specs = 79   (reed_solomon, photo_transfer)
W16: +2 specs = 81   (ofdm_fft256, video_stream)
W17: +1 spec  = 82   (fpga_bpsk_modem)
W18: +1 spec  = 83   (fpga_aes256)
W19: +1 spec  = 84   (fpga_ofdm)
W20: +1 spec  = 85   (integration)
```

## Dependency Graph

```
W12 (boards alive) ────────┐
W13 (mesh converge) ───────┤
W14 (chat UX) ─────────────┤── W20 (full demo)
                           │
W15 (photo) ───────────────┤
W16 (video) ───────────────┤
                           │
W17 (FPGA BPSK) ───────────┤
W18 (FPGA AES) ────────────┤
W19 (FPGA OFDM) ───────────┘
```

phi^2 + phi^-2 = 3
