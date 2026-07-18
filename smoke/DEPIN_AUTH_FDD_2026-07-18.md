# Authenticated frames + concurrent FDD sources (2026-07-18) -- "все три"

Two upgrades on the 4 P201Minis: a per-frame keyed MAC (so a node without the key cannot inject
frames) and two sources broadcasting AT THE SAME TIME on different frequencies. The third option
(DSSS on a big FPGA) stays blocked.

## 2 -- Per-frame keyed MAC (t27 SHA-256): authenticity, not just integrity

The CRC of the last wave detects RANDOM corruption but not a forged frame. This wave replaces it
with a keyed authentication tag: the K=4 coded frame is now 14 bytes -- `g:u16 | cv[4] | value:u32
| mac32:u32` -- where mac32 = first word of **SHA-256(key || the first 10 bytes)** via the t27
`tri_sha256`. For a fixed-length frame this is a secure MAC: without the key, an attacker cannot
produce a valid tag for a chosen frame. (The repo's `hmac_md5` is a stub XOR -- trivially
forgeable -- so it was NOT used.) The receiver recomputes the MAC under its key and DROPS any
frame that fails.

Forgery rejection (host + over the air): a "forger" node transmits coded frames signed with the
WRONG key.

```
                                verify with correct key K
genuine .13 + genuine .11   ->  3/3   mac_dropped small   -> "AUTH RLNC MESH .11+.13 KEYED OK"
genuine .13 + FORGER (K')   ->  0/3   mac_dropped=73       -> forger fully rejected
```

Over the air the forger transmitted continuously, yet EVERY one of its frames failed the MAC
(mac_dropped=73 copies) -- none reached the GF(256) solver. A node without the key cannot inject
false data into the coded mesh, and cannot make the destination decode a forged message.

## 1 -- Concurrent FDD sources: two senders on air at once

Instead of time-multiplexing (last wave turned one source off before the other), both genuine
sources transmit SIMULTANEOUSLY on different frequencies: **.13 @ 2.40 GHz and .11 @ 2.45 GHz at
the same time**. The destination .10 tunes its RX to each band in turn and harvests frames from
both; both were on air throughout. Decoded 3/3 with the correct key -> the exact message. The
network supports multiple simultaneous senders (frequency-division multi-access), and the coded
frames from the two bands combine exactly as the multi-source RLNC expects.

## Scientific picture

The CRC was a wax seal that only proved a letter had not smudged in the post; anyone could melt
their own wax and seal a fake. The keyed MAC is a signet ring: only the holder of the private ring
can stamp a valid seal, so a forged letter is spotted and binned before it is even read. And
frequency-division is two heralds proclaiming at once from opposite towers -- the listener turns
an ear to each, and because the messages are coded, it does not matter that they spoke together;
their fragments reassemble into one. Together: a mesh where many can speak simultaneously, and
only the keyed can be believed.

## Honest boundary

- The MAC is SHA-256(key || frame) truncated to 32 bits -> ~1/2^32 blind-forgery chance per
  attempt; it lacks a nonce, so it authenticates the frame content but does not by itself stop
  replay (a captured valid frame could be re-sent). A production link adds a nonce/sequence
  (full HMAC-SHA256 or Poly1305). Coding vectors are already unique per frame, which limits
  useful replays.
- FDD sources are still captured one band at a time by the single RX (both are on air together;
  the RX cannot listen to two 5 MHz-separated bands in one shot given its passband). A wide-band
  or two-RX capture is the next step.
- +4 B/frame for the MAC (14 vs 10 B). Uses the t27 tri_sha256 and the MDS-Vandermonde coding.

## DSSS on a big FPGA: still blocked

Re-scan: only .1 (router), .10/.11/.12/.13 (four P201Minis), the host. Needs Vivado + ADI-HDL.

Boards left clean: writers=0, TX LO pd=1 on .10/.11/.12/.13, LOs restored to 2.4 GHz, IQ removed.
