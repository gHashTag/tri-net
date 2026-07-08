# Daemon TUN Integration — IP-over-Mesh Run Loop (iter29)

**Date:** 2026-07-08
**Commit:** `a528a74` (trios-mesh)
**Tests:** 273 total (+7 integration +15 cumulative this wave)

## What

The daemon (`trios_radiod`) now supports IP-over-mesh. Enable with
`TRIOS_TUN=1`:

```
Application (curl, ssh, iperf3)
    |  IP packet
    v
/dev/net/tun (tritun0, 10.42.0.N/24)
    |  raw IPv4 packet
    v
tun::dst_node() -> NodeId
    |
    v
[TUN_TYPE][ip_packet...] -> router.send_ip(dst)
    |  encrypted mesh frame over RF
    v
Peer: router.handle_frame() -> Delivery::Local([TUN_TYPE][ip...])
    |
    v
tun_writer.write_packet(ip) -> kernel delivers to app
```

## Daemon Changes

1. **TUN_TYPE = 0x04** — new frame type for raw IPv4 packets
2. **LinuxTun** — `/dev/net/tun` ioctl wrapper in the binary (library stays `forbid(unsafe_code)`)
3. **TUN reader thread** — reads IP packets, maps dst to NodeId, wraps as TUN_TYPE, sends through router
4. **TUN writer in RX callback** — TUN_TYPE frames from peers → write to TUN device

## Platform Split

| Layer | Location | `unsafe`? |
|-------|----------|-----------|
| IP parsing + routing logic | `src/tun.rs` (library) | No (forbid) |
| TunDevice trait + MockTun | `src/tun.rs` (library) | No |
| `/dev/net/tun` ioctl | `src/bin/trios_radiod.rs` (binary) | Yes (binary allowed) |

## Integration Tests (7)

- `ip_packet_roundtrips_through_mesh_crypto` — byte-identical recovery
- `multiple_ip_packets_sequentially` — 10 packets, all match
- `bidirectional_ip_traffic` — A→B and B→A
- `large_ip_packet_survives_mesh` — 1400-byte MTU payload
- `mock_tun_full_pipeline` — inject→seal→transport→open→write
- `icmp_like_packet_through_mesh` — ping simulation
- `mesh_router_routes_ip_packet_to_correct_node` — routing table mapping

## Usage on Board

```bash
# On each board:
echo "id 11" > /tmp/mesh.conf
TRIOS_TUN=1 trios-radiod /tmp/mesh.conf &

# Configure the TUN interface:
ip addr add 10.42.0.11/24 dev tritun0
ip link set tritun0 up

# From node 11:
ping 10.42.0.22      # ICMP over encrypted mesh
ssh root@10.42.0.22  # SSH over encrypted mesh
curl http://10.42.0.22/  # HTTP over encrypted mesh
```

phi^2 + phi^-2 = 3
