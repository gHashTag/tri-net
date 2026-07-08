# Internet-via-Mesh Gateway (M4) — iter31

**Date:** 2026-07-08
**Commit:** `d8314b7` (trios-mesh)
**Tests:** 294 total (+11 gateway/route)

## What

A node with internet access (Ethernet to router) shares it with the mesh.
Non-gateway peers route non-mesh traffic (0.0.0.0/0) through the encrypted
mesh to the gateway, which NATs it out to the internet.

```
Board 2 (peer)                     Board 1 (gateway)
  curl google.com                    eth0 -> internet
    |                                  ^
    v                                  |  MASQUERADE
  tritun0 (10.42.0.2)                 |
    |  [TUN_TYPE][8.8.8.8 pkt]        |
    v                                  |
  encrypted mesh RF -----> tritun0 (10.42.0.1)
                                    |
                                    v
                                  kernel routes to eth0
```

## Gateway Protocol

1. **Gateway node** (`TRIOS_GATEWAY=1`): broadcasts `[GATEWAY_TYPE][node_id:4 LE]`
   every 5 seconds through the mesh
2. **Peer nodes**: track gateways in `GatewayTable`, elect lowest NodeId
3. **TUN reader**: `route_packet(ip, gateway)` — mesh IP → that node, non-mesh
   IP → best gateway
4. **Gateway expiry**: 10 missed announcements (50s) → gateway removed from table

## API

```rust
// GatewayTable
let mut gt = GatewayTable::new();
gt.announce(11);                    // node 11 is a gateway
gt.best()                           // Some(11) — lowest NodeId
gt.tick();                          // age gateways (call per HELLO cycle)

// Routing
let dst = route_packet(&ip, gt.best());
// mesh IP (10.42.0.22) -> Some(22)
// non-mesh IP (8.8.8.8) -> Some(11) [gateway]
// non-mesh + no gateway -> None [drop]
```

## Usage

```bash
# Board 1 (gateway): has Ethernet to internet
TRIOS_GATEWAY=1 TRIOS_TUN=1 trios-radiod /tmp/mesh.conf &
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -A POSTROUTING -s 10.42.0.0/24 -o eth0 -j MASQUERADE

# Board 2 (peer): routes internet through mesh
TRIOS_TUN=1 trios-radiod /tmp/mesh.conf &
ip addr add 10.42.0.2/24 dev tritun0 && ip link set tritun0 up

# From Board 2:
curl http://example.com    # via encrypted mesh -> Board 1 -> internet
ping 8.8.8.8               # via encrypted mesh -> Board 1 -> internet
```

## Tests (11 new)

**GatewayTable (8):**
- announce_and_query, gateway_expires, lowest_node_id_elected
- announcement_roundtrips, parse_rejects_malformed
- is_gateway_check, stale_gateway_replaced, non_mesh_ip_routes_to_gateway

**TUN routing (3):**
- route_packet_to_mesh_node, route_non_mesh_ip_to_gateway
- route_non_mesh_ip_no_gateway_drops

phi^2 + phi^-2 = 3
