# Secure Handshake over the Air — Results (Вариант B / B′-wire)

**Date:** 2026-07-08
**Component:** `trios-mesh` `src/bin/trios_radiod.rs` + `src/crypto.rs`
**Commits:** `8679ae0` (B′ crypto core), `a20e195` (B′-wire — on-air handshake)
**Goal:** the mesh must establish **authenticated, forward-secret** sessions
over the real radio — not just derive them in a unit test — and recover keys
cleanly after a node reboots, with no nonce reuse.

## What was built

An on-air handshake beacon that upgrades every link from the bootstrap
static-static session to an **authenticated + forward-secret** session.

Wire frame (plaintext, 37 bytes):

```
[0xE2 HS_MARKER][sender : u32 LE][ephemeral_public : 32 bytes]
```

- **Plaintext, intercepted before the session-open path.** `0xE2` can't be a
  valid encrypted frame's first byte (wire VERSION = 1), so the RX dispatch
  routes handshakes straight to the handler. Because they carry no AEAD, a
  handshake **cannot deadlock on a session mismatch** — which is exactly the
  state two nodes are in right after one reboots.
- **Beacon every 3 s** through the same modem (+ FEC, if enabled) path as data.
- **On RX**, a peer's *new* ephemeral triggers
  `StaticKey::session_authenticated(peer_static, my_eph, peer_eph, initiator)`
  — mixing `DH(static,static)` (authentication) with `DH(eph,eph)` (forward
  secrecy) via SHA-256 → HKDF — and **replaces the link's session in place**.
- **Bootstrap-then-upgrade.** The mesh comes up immediately on the old
  static-static session and silently upgrades once the peer's handshake lands, so
  there is no cold-start window with no connectivity.
- **Reboot resync.** A reboot mints a fresh ephemeral; the far side sees a new
  ephemeral from that sender and re-keys. No ephemeral is ever reused across a
  reboot, so **no nonce is ever reused**.
- **Idempotent.** A repeat of the same ephemeral is ignored, so the 3 s beacon is
  one 37-byte frame per peer with zero re-key churn.

## Software end-to-end (host)

`cargo test` — **136 green** (132 lib/integration + 4 new bin tests):

| Test | Proves |
|------|--------|
| `handshake_frame_roundtrips` | build → parse is exact |
| `parse_rejects_malformed` | short / wrong-length / wrong-marker frames rejected |
| `handshake_survives_the_modem` | 37 B frame demods intact through `tx_shaped`→`rx_recover` |
| `both_sides_derive_the_same_authenticated_session` | two nodes exchange frames → **seal on one side opens on the other** |
| `crypto::authenticated_fs_handshake` | the DH mix is authenticated + forward-secret |
| `crypto::reboot_gets_a_fresh_session_no_nonce_reuse` | reboot → fresh session, no nonce reuse |

## Hardware smoke (board 11, `192.168.1.11`, Zynq-7020 + AD9361)

Cross-built `armv7-unknown-linux-musleabihf`, ssh-cat deployed (md5 verified),
run 18 s on the live 2.4 GHz air:

```
[radiod] identity: real key (/tmp/mesh.conf.key), public 9f4a0cb5…8246c
[radiod] node 11 on 2.4 GHz air — peers [12, 13]
[radiod] rx HANDSHAKE from node 11        ← beacon heard off its own air
… (×5 in 18 s ≈ one per 3 s beacon)
```

- Real secret key generated + loaded (0600), public printed for peer trust.
- **Handshake beacon transmitted and self-received 5× in 18 s** — proving the
  full path a peer's handshake takes: **beacon TX → BPSK modem → RX burst-slice →
  demod → `parse_handshake` → sender check**. The board correctly identified its
  own beacon (`sender == 11`) and dropped it (self can't upgrade a session).
- **Zero panics / errors.** 482 RX bursts sliced off the busy air (normal for a
  crowded 2.4 GHz band; most fail demod and are discarded).

## Honest status — what is NOT yet proven on hardware

The one property a **single** board cannot demonstrate is two **physical** boards
exchanging *distinct* ephemerals and both deriving the matching authenticated+FS
session over the air (session upgrade only fires for `sender != me`). That path
is covered by the software E2E test (`both_sides_derive_the_same_authenticated_session`)
and the crypto core, but the over-air two-board convergence needs a second board
on the network — boards 12 and 13 are radio-only (no Ethernet) at the moment.

**To close it:** briefly replug Ethernet on board 12 (or 13), deploy the same
binary, run both with matching peer static keys, and confirm each logs
`HANDSHAKE node <peer>: session upgraded (authenticated + forward-secret)`
followed by a successful encrypted DATA delivery. Estimated 10 min with one
board replugged.
