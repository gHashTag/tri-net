# Channel P — Photo Transfer: Results (2026-07-08)

Status: PROVEN at the PHY + protocol level (host, no hardware needed). A real
18.5 KB photo went through the ENTIRE radio stack and came out byte-identical.
Channel T (text/data) was done; this is the next channel — photo.

## The problem
A photo is 10s–100s of KB; a mesh frame carries ~90 bytes of app payload
(255 B modem − FEC − mesh header − AEAD). So a file must be fragmented into
numbered chunks, each sent as one mesh frame, and reassembled on the far side —
over a lossy link, so with retransmission and an integrity check.

## What was built (`trios-mesh`, PR #22)
- `src/filexfer.rs` — fragment / reassemble, CRC-32 over the whole file, a
  per-chunk crc16 (a corrupted chunk is rejected → stays "missing" → the next
  NACK re-requests it), wire types META / CHUNK / NACK / DONE, and an `Rx`
  reassembly state machine. **4 host tests**, incl. a 12 KB file over a
  **40 %-loss channel** reassembling byte-identical, and a CRC-mismatch reject.
- `src/bin/trios_radiod.rs` — `TRIOS_SENDFILE=<dst>:<path>` sender (fragment,
  send META + all chunks, resend on NACK) + a receiver thread (periodic NACK
  of missing chunks; on completion verify CRC, write `/tmp/rx_<name>`, DONE the
  sender). Chunk size 88 B keeps the sealed frame ≤ the FEC 144 B limit.
- `examples/photo_over_radio.rs` — the end-to-end proof.

## End-to-end proof (full stack, host)
`photo_over_radio` pushes a real 18,555-byte PNG (211 chunks) through:
`fragment → FEC(Hamming 7,4) → BPSK modem → noisy channel (σ=0.25, 15 % drop)
→ demod → FEC-decode → per-chunk CRC → NACK reassembly → file CRC`.

```
photo: 18555 bytes, 211 chunks, crc f0a0e8cb | channel: sigma=0.25 drop=15%
  round 1: 172/211 chunks, 39 still missing
  round 2: 204/211 chunks, 7 still missing
  round 3: 209/211 chunks, 2 still missing
  round 4: 211/211 chunks, 0 still missing
DONE: 4 rounds, 211 chunk-deliveries, 95 FEC-corrected frames
OUTPUT (18555 bytes) — byte-identical to input: YES | CRC: OK
```
`md5(input) == md5(output)` (d0e2ee8d…), pixels identical. The same code paths
(`filexfer` + `fec` + `modem`) run on the boards — the only missing piece for
an over-air photo is running it on two radios (needs a 2nd board plugged in to
deploy the new daemon).

## What this means for the roadmap
- Channel T (text/data): DONE (internet over the air, wire-free).
- **Channel P (photo): protocol + PHY proven byte-identical on host** — over-
  radio 2-board demo is a deploy-and-run away.
- Channel V (video): the streaming extension — send frames continuously,
  tolerate loss without whole-file reassembly (display latest complete frame),
  add a faster PHY (QPSK/OFDM) and FPGA offload for the bitrate.

## Next
- Over-radio photo: deploy the daemon to two boards, `TRIOS_SENDFILE=13:photo.png`
  on the sender, watch `FILE RECEIVED … CRC OK` on the receiver (needs a board
  plugged in to deploy).
- Bit interleaver in FEC (spread bursts) to cut the retransmit rounds.
- Channel V: streaming file/video mode + QPSK for throughput.
