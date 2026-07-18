# $TRI DePIN over a lossy radio channel — RF measurement + integrity gate (2026-07-18)

## Weak point (from the literature)

Prior waves proved the Proof-of-Relay receipt over Ethernet/HTTP, where forwarded
bytes are bit-exact. Over a real radio link they are NOT: decode-and-forward relays
carry intra-link bit errors (BER > 0). A bit-exact receipt then (a) punishes an
honest relay for the channel's errors — one flipped bit → a completely different
seal → no reward for real work — and (b) cannot distinguish a channel error from
cheating. This is the "lossy untrusted decode-and-forward relay" problem.

## Real channel measured on THIS hardware

Node .13 transmits a DDS tone (2400 MHz + 1 MHz, TX gain −10 dB); node .12 captures
8192 IQ samples with `iio_readdev`:

- noise floor: RMS 7.4 (P = 55, int16 units)
- tone + noise: RMS 1732 (P = 3.0e6), max |·| = 2092
- **SNR = 47.4 dB** → uncoded BPSK BER ≈ 0

So the bench link .13→.12 is clean enough that forwarded bytes arrive bit-exact
(consistent with the prior BER=0 result). The integrity gate below is the insurance
for weaker/interfered links, not a crutch for this one.

## Fix: integrity-gated relay metering (t27)

`specs/tri_depin.t27` gains `relay_absorb_verified` and `bytes_add_verified`: the
relay meters a datagram ONLY if the digest it recomputes over the received bytes
matches the digest the datagram carries. A channel-corrupted datagram is dropped —
not metered. The receipt covers exactly the bytes the node correctly received and
forwarded: no penalty for the channel (dropped bytes just are not counted), no false
reward for corrupted ones. 18 invariants pass via the golden pipeline, including
`verified_lossy_equals_clean_subset` (a stream with a corrupted middle datagram
meters identically to the clean stream with that datagram removed).

## Proven on the node ARM (relayfec mode, payload = 20851-byte pitch HTML)

| Channel | dgrams | accepted | dropped | metered | seal == clean? |
|---------|--------|----------|---------|---------|----------------|
| BER 0 (our 47 dB link) | 82 | 82 | 0 | 20851 | **yes** (0x315A32C9) |
| BER 100 ppm | 82 | 72 | 10 | 18291 | no |
| BER 1000 ppm (0.1%) | 82 | 16 | 66 | 3955 | no |

At the real link (BER≈0) the relay is metered bit-exact — the receipt matches, the
relay is provably forwarding the right bytes. As the channel degrades the gate drops
corrupted datagrams and meters only what was correctly forwarded — honest under loss.
ARM (.12) and x86 host produce identical numbers (cross-arch bit-exact).

## Honest boundary

- The channel-error injection (`relayfec`) is a deterministic model at a chosen BER;
  the 47 dB SNR is a real measurement, but a full live OTA byte transfer through the
  modem (TX modulate → RX demod → bytes) is still the next step to meter genuinely
  radio-delivered bytes end-to-end.
- The integrity gate detects corruption and drops; it does not CORRECT errors. Pairing
  it with the repo's FEC (interleaved XOR parity) would recover more datagrams before
  the gate, raising the accepted fraction on a lossy link.

Boards left clean: capture files removed, TX DDS tone off, TX LO powered down (pd=1)
on .11/.12/.13.
