# T27 migration tracker — hand-written code → spec-first

Goal (from the /loop directive): move hand-written logic into `.t27` specs (the golden pipeline's source of
truth), so the Rust node `include!`s generated code instead of hand-authoring business logic.

## HONEST SCOPE — what can and cannot be flipped

- **Swift app (`phone/`, 27 files): CANNOT be t27.** T27 emits Verilog / C / Rust / Zig — NOT Swift. The
  video-call UI (AVFoundation, VideoToolbox, SwiftUI) has no t27 target. It stays hand-written by necessity.
- **Rust business logic (`src/*.rs`, 11 files, ~6.4k lines): PARTIALLY flippable.** Only the PURE
  integer/bool logic cores map to t27 (no f32, no I/O, no crypto primitives). This is the wire.rs precedent: a
  "partial flip" — the verifiable integer core goes to a spec, gets generated, and `src/*.rs` `include!`s it +
  wraps it in idiomatic Rust. Floating-point DSP (f32 sqrt/powi), sockets, TUN, and X25519/ChaCha primitives
  remain hand-written.
- **`src/bin/*` thin wrappers + `tun_dev.rs` (I/O): stay hand-written** (allowed by the golden pipeline).

## The flip recipe (per file)

1. Identify the pure integer/bool core (thresholds, ladders, bit layout, validity checks).
2. Write `specs/<name>.t27` with `fn` + `test`/`invariant` blocks (specs without tests are FORBIDDEN).
3. `../t27/target/release/t27c parse` + `typecheck` (0 errors) + `gen-rust` (eyeball it matches).
4. Wire `src/<name>.rs` to `include!("../gen/rust/<name>.rs")` + wrap. (Careful: `gen/` is a build-regenerated
   trap; the no-gen-edits hook guards it. Do this step deliberately, verify `cargo build` + `cargo test`.)

## Status

| file | lines | pure core | spec | typecheck | wired (include!) |
|---|---|---|---|---|---|
| wire.rs | 170 | header/kind/BE bytes | wire.t27 | ✅ | ✅ (precedent) |
| rti.rs | 844 | (partial) | rti_security.t27 | ✅ | partial |
| **rti_alert.rs** | 174 | **severity ladder** | **rti_alert.t27** | ✅ | ✅ include! wired, cargo test 3/3 (2026-07-22) |
| discovery.rs | 432 | HELLO layout/gates/freshness | discovery.t27 | ✅ | ✅ include! wired, tests 14/14 (2026-07-22) |
| routing.rs | 511 | ETX metric (fixed-point milli) | routing_etx.t27 | ✅ | ETX metric + RFC8966 feasibility/learn spec-first, equivalence test pinned to f32 (routing 19/19); live-path rewire pending radio test (2026-07-22) |
| modem.rs | 781 | frame geometry / sync gate | modem_frame.t27 | ✅ | ✅ include! wired + equivalence test, modem 23/23 (2026-07-22) |
| gf16.rs | 663 | GF16 fixed-point (host DSP model) | NONE | — | — |
| router.rs | 1350 | TTL + forwarding decision | router_ttl.t27 | ✅ | ✅ include! wired + equivalence + behavioral tests, router 27/27 (2026-07-22) |
| crypto.rs | 907 | nonce/epoch/replay-window integer logic only | NONE | — | — |
| daemon.rs | 328 | (mostly orchestration/I/O) | — | — | — |
| tun_dev.rs | 204 | I/O — NOT t27 | — | — | — |

## Next iterations (one safe verified flip each)

1. Wire `rti_alert.rs` to `include!` the generated `alert_severity` (verify cargo build+test).
2. `discovery.rs` HELLO byte-layout `fn`s (like wire.rs) → `specs/discovery.t27`.
3. `routing.rs` ETX integer metric + next-hop comparison → `specs/routing.t27`.
4. `crypto.rs` — ONLY the nonce/epoch/replay-window integer bookkeeping (NOT X25519/ChaCha20, which t27 can't
   express); leave the AEAD primitives as vetted Rust crates.
