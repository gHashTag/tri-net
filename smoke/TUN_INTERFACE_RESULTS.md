# TUN Interface — IP-over-Mesh Plumbing (iter28)

**Date:** 2026-07-08
**Commit:** `e007137` (trios-mesh)
**Tests:** +8 (266 total)

## What

`src/tun.rs` bridges the mesh daemon and the kernel networking stack:

```
Application (curl, ssh, iperf3)
    ↓ IP packet
TUN device (10.42.0.N/24)
    ↓ raw IPv4 packet
tun::dst_node() → NodeId
    ↓
Node::seal_data(dst, ttl, ip_packet)
    ↓ encrypted mesh frame
UDP / RF transport
    ↓
Node::open_data() → plaintext IP packet
    ↓
TUN write_packet() → kernel delivers to app
```

## API

```rust
// Parse a raw IPv4 packet to find the mesh destination
let dst = tun::dst_node(&ip_packet)?; // Some(22) for 10.42.0.22

// Check if a packet is for this node
if tun::is_for_us(&packet, our_id) { ... }

// Trait for testability
trait TunDevice {
    fn read_packet(&mut self) -> io::Result<Vec<u8>>;
    fn write_packet(&mut self, packet: &[u8]) -> io::Result<()>;
}
```

## IP Addressing

Each mesh node N gets `10.42.0.N/32` via `mesh_ip(N)`. The TUN device is
assigned `10.42.0.{this_node}/24`. On Linux: `ip addr add 10.42.0.11/24
dev tun0`. Routes to other nodes go through the TUN automatically.

## Platform Split

- **Library** (`src/tun.rs`): pure-safe parsing + traits + mock. No unsafe.
- **Binary** (`src/bin/trios_radiod.rs`): real `/dev/net/tun` ioctl. Can use unsafe.
- **macOS**: `MockTun` for tests (no real TUN needed).

## Tests

- `parse_dst_ipv4_from_synthetic_packet` — correct extraction
- `parse_rejects_short_packet` — < 20 bytes → None
- `parse_rejects_ipv6` — version ≠ 4 → None
- `parse_rejects_non_mesh_ip` — 192.168.x.x → None
- `is_for_us_checks_destination` — correct match
- `ip_packet_through_mesh_encrypts_and_routes` — **end-to-end**: synth_v4
  → seal_data → open_data → byte-identical recovery, dst_node verified
- `mock_tun_fifo_roundtrip` — FIFO queue works
- `tun_write_succeeds_on_mock` — no error on write

## What This Unblocks

- **iperf3 through the mesh** — once the daemon wires TUN I/O, any IP
  application works over the mesh without modification
- **SSH over mesh** — `ssh root@10.42.0.22` goes through encrypted RF
- **Browser over mesh** — HTTP proxy to 10.42.0.N
- **M3 milestone** (iperf3 over 2 hops) — the TUN path is the M3 path

phi^2 + phi^-2 = 3
