# trios-mesh

**TRI-NET drone-mesh daemon** — encrypted, self-routing IP-over-radio for the
P201/P203 **Zynq-7020 Mini** node. The mesh layer of "Starlink without satellites":
relay drones + fixed nodes sharing one internet uplink. Part of the Trinity Project.
Anchor: **φ² + φ⁻² = 3**.

> **Status (2026-07-01):** M1 crypto core is implemented and **host-tested** (`-sim`).
> It graduates to `hw` once it runs on the real Zynq Mini ARM-Linux node — whose
> FPGA/PS has never been flashed yet (see `gHashTag/tri-net`#8). Not on hardware = `-sim`.

## What it is

A small, dependency-light Rust crate providing the mesh building blocks:

| Module | Responsibility | Milestone |
|---|---|---|
| [`crypto`](src/crypto.rs) | X25519 handshake → HKDF-SHA256 session key → ChaCha20-Poly1305 AEAD, directional 96-bit nonce, 64-frame replay window | **M1** |
| [`routing`](src/routing.rs) | ETX metric (`1/(d_f·d_r)`) neighbor table, best next hop | M2 |
| [`discovery`](src/discovery.rs) | HELLO beacons (who-hears-whom → forward delivery ratio) | M2 |
| [`wire`](src/wire.rs) | datagram header, doubles as AEAD associated data | M1/M2 |
| [`daemon`](src/daemon.rs) | node skeleton wiring the above; `Transport` trait for UDP/TUN/radio | M2 |
| [`gf16`](src/gf16.rs) | GF16 (1-6-9, bias 31, no-subnormal) host DSP model of the OFDM FFT/equalizer; the win is multiplier **width/area** (≥2× taps per DSP48), **not** accuracy | M2 `-sim` |

## Milestone ladder

- **M1** — X25519 + ChaCha20-Poly1305 on a real ARM node. ✅ *implemented, host-tested*
- **M2** — TUN/netdev IP-over-radio with a real ETX metric.
- **M3** — iperf3 over 2 hops through attenuators (P1 exit gate).
- **M4** — share ONE uplink across a 3-node triangle (P2 DEMO GATE).
- **M5** — self-healing re-route with a measured convergence time (P2 DEMO GATE).

## Build & test

```bash
cargo test              # 20 unit + 2 integration tests
cargo run --bin smoke-m1
```

Expected `smoke-m1` output:

```
[M1] X25519 handshake complete: node 1 <-> node 2
[M1] AEAD round-trip OK: 44 bytes plaintext -> 79 bytes on-wire (ChaCha20-Poly1305)
[M1] tamper rejected: flipped tag bit -> Auth error
[M1] replay rejected: re-delivered frame -> Replay error
[M1] PASS (-sim). Re-run on the Zynq Mini ARM node to graduate to hw.
```

## Cross-compiling for the Zynq Mini (Cortex-A9, 32-bit ARMv7)

```bash
rustup target add armv7-unknown-linux-gnueabihf
cargo build --release --target armv7-unknown-linux-gnueabihf
# scp target/armv7-unknown-linux-gnueabihf/release/smoke-m1 to the Mini, run on-device,
# record the result in smoke/M1_RESULTS.md — that graduates M1 from -sim to hw.
```

## Design notes

- **Directional nonces.** Initiator sends with nonce direction byte `0`, responder `1`,
  so the two TX counters never collide within one session key.
- **Auth before replay.** A frame's tag is verified before the replay window is
  consulted, so forged counters can't poison the window.
- **Header is authenticated.** The wire header (src/dst/ttl) is passed as AEAD
  associated data — a flipped routing byte fails authentication.
- **No `unsafe`** (`#![forbid(unsafe_code)]`); crypto is RustCrypto + dalek.

## License

Apache-2.0.
