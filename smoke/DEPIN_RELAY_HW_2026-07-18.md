# $TRI DePIN Proof-of-Relay — on-hardware verification (2026-07-18)

Wave goal (option A from the prior report): wire the `tri_depin.t27` Proof-of-Relay
accumulator into a real forwarding path and prove the receipt end-to-end on the
P201Mini node ARM, with independent cross-machine verification.

## Weak point found and fixed (spec)

The prior `epoch_seal(acc, node_key, epoch)` did **not** bind `total_bytes` — but
the settlement layer pays proportional to `total_bytes` (a separate saturating
counter). A node could present its honest `acc`/seal yet claim an inflated
`total_bytes` and be over-paid; `verify_epoch` never looked at the byte count.

Fix: `epoch_seal(acc, total_bytes, node_key, epoch)` now binds the reward quantity.
Added invariants `seal_total_bytes_bound` and `verify_rejects_byte_inflation`.
Golden pipeline (`t27c gen-rust` → `rustc --test -O`): **14/14 invariants pass**.

## Build

- Logic: `specs/tri_depin.t27` → `t27c gen-rust` (verbatim, embedded in a thin
  binary wrapper — orchestration only, per repo law).
- Meter binary: `cargo zigbuild --release --target armv7-unknown-linux-musleabihf`
  → static musl ARM ELF, 371 KB.
- A datagram = 256-byte chunk of the relayed stream; its digest = the bytes folded
  through `mix32` (content-derived, so any verifier re-deriving from the same bytes
  reproduces the receipt).

## Result (real hardware)

Payload = a real 19974-byte file (the pitch HTML), byte-identical on host and both
nodes (md5 `ee4519851fb0dfc0299e8cf05ab4f74f`), key `0xB0A12345`, epoch 7.

| Actor | Action | Output |
|-------|--------|--------|
| **.12 ARM** | `meter` real payload | `dgrams=79 total_bytes=19974 acc=0xDB1DEC6F seal=0xDA1E6433` |
| **host x86-64** | re-meter + `check` | ACCEPT, identical `acc/seal` |
| **.13 ARM** | re-meter + `check` (2nd node) | ACCEPT, identical `acc/seal` |
| host | claim 500000 bytes (real seal) | **REJECT** byte-count forgery |
| host | tampered payload (1 byte flipped) | **REJECT** seal mismatch (0xEC329D4B) |
| .13 ARM | tampered payload | **REJECT** seal mismatch |

**Cross-architecture bit-exactness**: a seal minted on the ARMv7 node is recomputed
identically on x86-64 and on a second ARM node — endianness, u32 wrapping, and shift
semantics all agree. This is exactly the property a settlement layer needs to verify
any node's receipt regardless of hardware.

## Honest boundary

- Verification is symmetric (shared/registered `node_key`), not yet a public-key
  signature — a node that knows its own key could still fabricate a self-consistent
  receipt over fake content. Independent re-metering of the real stream (as done
  here) catches that; an asymmetric **signature over the seal** is the next step.
- The stream metered here is a real file replayed through the meter, not yet the
  live mesh-daemon forwarding path. Wiring `relay_absorb` into `trios_meshd`'s real
  ingress is the next integration step.
- No on-chain $TRI issuance; the receipt is the input a settlement contract consumes.

Boards left clean: pushed files removed, TX LO powered down (pd=1) on .11/.12/.13.
