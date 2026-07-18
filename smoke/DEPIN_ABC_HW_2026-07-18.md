# $TRI DePIN A+B+C on real hardware (2026-07-18)

All three next-Wave options done end-to-end on the P201Mini nodes.

- **A — real forwarded bytes, not a local replay.** Node .13 serves the payload
  over HTTP (`busybox httpd`); node .12 fetches it over the wired network
  (`wget`) and meters the received stream. The metered bytes genuinely traversed
  a network link between two nodes. (RF/over-the-air leg is still the next step;
  the boards have no `nc`/`socat`, only `wget`/`httpd`, so HTTP is the transport.)
- **B — Ed25519 signature (asymmetric, replaces the shared-secret check).** Node
  .12 signs the 20-byte receipt (key‖epoch‖total‖acc‖seal) with its private key
  (ed25519-dalek, cross-compiled to armv7 musl). The seal is still computed by the
  t27 spec; only the signature is a standard crate primitive (as the mesh uses
  ChaCha/X25519 crates). Verifiers need only the node's PUBLIC key — no shared
  secret, which is what lets a settlement layer scale.
- **C — settlement aggregator (`specs/tri_settle.t27`).** Sums verified per-epoch
  bytes into a round total and splits a token pool proportionally to metered bytes
  (u64 fixed-point, floor division => no over-issuance). 8 invariants pass via the
  golden pipeline.

## Run (real hardware, payload = 20474-byte pitch HTML, key 0xB0A12345, epoch 7)

| Actor | Action | Result |
|-------|--------|--------|
| **.13 ARM** | serve payload over HTTP | httpd up |
| **.12 ARM** | `wget` from .13 + `sign` | `total=20474 acc=0xA98467B7 seal=0x39F2B6E5` + Ed25519 sig |
| **host x86-64** | `vrfy` (public key only) | **VALID** |
| **.13 ARM** | `vrfy` (2nd node, public key) | **VALID** |
| host | vrfy with inflated total (9999999) | **INVALID** (sig covers all fields) |
| host | vrfy with wrong public key | **INVALID** |
| **.12 ARM** | `settle 1000 60474 20474 40000` | node0=338, node1=661 $TRI, paid=999 ≤ pool |

The seal minted on the ARM node is bit-exact with the host and the 2nd ARM node,
now over bytes that actually crossed the network. The signature makes the receipt
unforgeable and node-authenticated without any shared secret; the settlement split
conserves the pool.

## Honest boundary

- Transport is HTTP over Ethernet, not the radio. Over-the-air relay (raise the
  .13→.12 RF link, meter what the radio forwarded) is the remaining step.
- The signing seed is passed on the command line here; a real node keeps its
  private key in secure storage.
- Reward split is flat-proportional to bytes; quality/coverage weighting (Helium
  scores its PoC) is future work.
- No on-chain issuance; `settle` output is what a settlement contract consumes.

Boards left clean: files removed, httpd stopped, TX LO powered down (pd=1) on
.11/.12/.13.
