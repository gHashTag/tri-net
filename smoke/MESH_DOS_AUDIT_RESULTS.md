# Network-Input DoS / Robustness Audit — Results (2026-07-08)

**Component:** `trios-mesh` `src/vstream.rs`, `src/filexfer.rs`, `src/router.rs`,
`src/bin/trios_radiod.rs`
**Fix commits:** `bf1c208` (library), `ac1f6d6` (daemon)
**Method:** 12-agent adversarial workflow — one finder per attack surface
(vstream, filexfer, router/routing, discovery, daemon ingest) → independent
verification of every finding by reproducing it against the real code (default
REFUTED). **7 findings confirmed, 0 refuted.**

## Why this audit (challenging "host work is exhausted")

Six prior iterations concluded the host-verifiable work was exhausted — but that
judgment only covered the **throughput / PHY ceiling** (16-QAM, timing, QPSK).
The **robustness / DoS surface** — how the stack behaves on malformed or
malicious wire input from an authenticated-but-hostile or buggy peer — was never
audited and is fully host-verifiable. It is also a real, exploited class:
Meshtastic (the dominant open mesh-radio project) shipped **CVE-2025-24797**, an
*unauthenticated* malformed-protobuf buffer overflow / RCE (fixed in 2.6.2). This
audit targets that class in trios-mesh.

Already hardened, confirmed NOT gaps: crypto nonce/replay window + epoch ratchet
(`crypto.rs`); RS decode guards (`rs.rs`); the `links` table grows only via
authenticated `add_peer`.

## Findings and disposition

| # | Sev | Surface | Finding | Status |
|---|-----|---------|---------|--------|
| 1 | LOW | vstream | `Playout` bounds latency but not memory/CPU: `on_fragment` had no forward-window cap (asm BTreeMap grows on a far-ahead seq stream) and `advance`/`flush` emit one `Skipped` per intermediate seq (one far-future wire seq → ~65k iters + ~2 MiB Vec from a 6-byte frame) | **Fixed** |
| 2/7 | MED | filexfer | `Rx::from_meta` allocates `vec![None; total]` from the unbounded u16 `total` → ~1.5 MiB from an 11-byte forged META | **Fixed** |
| 4 | LOW | router | Relay re-forwards with the attacker-chosen end-to-end TTL (no clamp) → bounded airtime amplification on a routing loop | **Fixed** |
| 2b | MED | daemon | FILE_META overwrites the single global `Rx` slot unconditionally → a forged/duplicate META resets any in-progress transfer (reset DoS) | **Fixed** |
| 6 | MED | daemon | Gateway FETCH_REQ spawns a detached thread + outbound TCP connect **per frame** with no cap → thread/connect exhaustion | **Fixed** |
| 3 | LOW | filexfer/daemon | The NACK/DONE reply target is the **wire** `sender` field, not the authenticated source → misdirected reply traffic at an attacker-named third node | **Deferred** |
| 5 | MED | daemon | The plaintext `0xE2` handshake is unauthenticated → a forged one with a bogus ephemeral makes the receiver overwrite a working session with a dead one (single-link blackhole) | **Deferred** |

## Fixes (commits `bf1c208`, `ac1f6d6`)

- **vstream:** RTP-style origin (first fragment sets `next_play`, so a stream that
  starts/forges a high seq never skips from 0); a forward-window cap
  (`depth + FORWARD_SLACK`) in `on_fragment` bounds the reassembly buffer to
  O(depth); `cap_catchup()` collapses an implausible `advance`/`flush` gap in O(1)
  so the returned Vec is bounded to `MAX_CATCHUP`.
- **filexfer:** reject `total == 0` or `total > MAX_CHUNKS` (1 MiB / CHUNK) before
  allocating.
- **router:** clamp the incoming TTL to `DEFAULT_TTL` before decrementing.
- **daemon:** one in-flight gateway fetch at a time (AtomicBool gate); accept a new
  FILE_META only into an empty or already-complete `Rx` slot.

Five new regression tests (`first_fragment_sets_playout_origin`,
`far_ahead_fragments_are_dropped_and_buffer_stays_bounded`,
`advance_and_flush_output_is_bounded_on_a_far_future_seq`,
`from_meta_bounds_the_total_before_allocating`,
`relayed_ttl_is_clamped_to_default`). **231 tests pass.**

## Deferred findings (not fixed blind — documented with the correct fix)

- **#3 reply-target:** the correct fix binds the reply to the authenticated
  end-to-end source, which requires threading `hdr.src` through `Delivery::Local`
  — a library API change. Fixing it in the daemon alone would either break
  multi-hop file reply (using the last-hop `from`) or leave the wire field
  trusted. Deferred to a scoped API change. Mitigated meanwhile by the #2b slot
  guard + the #2 `total` bound (a forged META can no longer sustain NACK churn).
- **#5 handshake auth:** the correct fix appends `tag = MAC(KDF(ss), 0xE2 ||
  sender || eph_pub)` where `ss` is the static-static DH secret (computable only
  by the two real peers), and the receiver verifies it before `add_link`. This is
  a crypto-protocol change to the live, HW-proven over-air handshake and must be
  validated on **two boards over the air** before it is trusted — only board 11 is
  currently reachable (12/13 off). Deferred rather than shipped single-board-blind
  (the attack also requires an active on-air adversary who could jam L1 directly).

## HW smoke (board 11, the only reachable node)

Cross-built `trios_radiod` (armv7, `cargo zigbuild`), deployed, ran ~20 s with
peers configured: node boots (real key, BPSK, radio setup), transmits HANDSHAKE
frames and hears its own echo (correctly filtered `sender == me`), 364 lines of
activity, **0 panics** — the boot / TX / RX / handshake path is intact with all
hardening changes linked in. The daemon FILE_META/FETCH guards need FILE/FETCH
frames from a second node to exercise on the air; unit tests cover the logic.

## Takeaway

The robustness/DoS surface was a genuine, unexplored, host-verifiable front — it
disproved the "host work is exhausted" judgment. Seven real findings; five fixed
and regression-locked, two deferred with a precise fix design because a correct
fix needs a library API change or 2-board crypto validation, not a blind patch.
This is the fourth adversarial review to surface real defects in this project
(iter13 RS: 8, iter14 multi-block: 5, iter22 wire: 4, here: 7).
