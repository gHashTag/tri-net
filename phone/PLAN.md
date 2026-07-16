# TRI-NET Phone App — Video over Mesh

## Architecture
Phone (camera+codec) ←UDP→ P203 Mini (mesh radio) ←radio→ P203 Mini ←UDP→ Phone (display)

## E1: Loopback test (2-4h)
Phone camera → H.264 → UDP → mesh loopback → UDP → Phone display

## E2: Two-phone (4-6h)  
PhoneA → node1 → radio → node2 → PhoneB

## E3: Multi-hop (6-8h)
PhoneA → node1 → node2 → node3 → PhoneB

## Tech stack
- Flutter (cross-platform)
- camera plugin (capture)
- mediarouter (H.264 encode/decode)  
- UDP socket (transport to mesh node)
- P203 Mini: trios_meshd UDP bridge mode

## Competitors
- Meshtastic: text only, no video
- Signal: central server, not mesh
- MPU5: military $4000+, Android-based but heavy
- Rajant: industrial mesh, no phone integration

## TRI-NET advantage
- Open source (Apache 2.0)
- FPGA mesh radio (5.8GHz, long range)
- Phone as lightweight endpoint (no radio hardware needed)
- Military-grade crypto (ChaCha20-Poly1305, per-hop)

phi^2 + phi^-2 = 3
