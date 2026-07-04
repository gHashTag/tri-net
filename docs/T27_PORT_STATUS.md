# Rust -> T27 port status (tri-net#16)

Porting the mesh from Rust to the T27 spec-first language (`.t27` -> Verilog via `t27c`).
T27 is an INTEGER hardware-datapath language; non-hardware logic (crypto bignum, float
DSP, async I/O) stays in Rust. Proof of a port = the spec's `test` blocks pass in `vvp`
on the generated Verilog, matching the Rust module's tests.

| Rust module | T27 spec | Status | Notes |
|---|---|---|---|
| `src/wire.rs` | `specs/wire.t27` | ✅ T27-FIRST (partial) | Constants + predicates auto-generated into `gen/rust/wire.rs` via `t27c gen-rust`; byte-layout stays hand-written; 101 lib tests + 25 M2 pure-logic tests still green. See `docs/T27_FIRST_MIGRATION.md` |
| `src/modem.rs` (BPSK core) | `t27/specs/fpga/bpsk.t27` | ✅ PORTED | modulator + Barker-13 correlator (on t27 master) |
| `src/modem.rs` (RX DSP: RRC/timing/CFO) | — | ❌ NOT PORTABLE | floating-point; T27 is integer |
| `src/routing.rs` (ETX metric) | `specs/etx.t27` | ⬜ TODO | integer/fixed math ports; dynamic tables need array/RAM (t27#1258) |
| `src/gf16.rs` (OFDM numeric) | `specs/gf16_ofdm.t27` | ⬜ TODO | maps to T27 GF16 domain |
| `src/daemon.rs` (Node/Transport) | — | 🟡 PARTIAL | FSM/framing ports; byte-pipe I/O does not |
| `src/discovery.rs` (HELLO) | — | 🟡 PARTIAL | counters/timing port; I/O does not |
| `src/crypto.rs` (X25519/ChaCha20/HKDF) | — | ❌ NOT PORTABLE | bignum field arithmetic + AEAD; out of scope for a spec-first HW language |

phi^2 + phi^-2 = 3
