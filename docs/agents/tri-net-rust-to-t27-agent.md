# Local-agent task: rewrite the tri-net mesh from Rust -> T27 (.t27), incrementally

**Repo (code + issues):** `/Users/ssdm4/Desktop/PROJECTS/CLAUDE/tri-net` (GitHub `gHashTag/tri-net`, private). Work off `main`; `Closes #<sub>` / `Refs #16` in PRs.
**Tracking issue:** #16. **Skill:** run `/t27-fpga-spec` first (T27 language, backend do/don'ts, validation, gotchas). Anchor: `phi^2 + phi^-2 = 3`.
**T27 compiler `t27c`:** in the sibling repo — `cd /Users/ssdm4/Desktop/PROJECTS/CLAUDE/t27 && cargo build --release -p t27c` -> `./target/release/t27c`. Also need `iverilog`/`vvp` (installed).

---

## Mission
Port the mesh from Rust to **T27 spec-first** (`.t27` -> Verilog/C/Rust/Zig via `t27c`). Continue **one module per PR**, and be **honest**: T27 is an INTEGER hardware-datapath language — most of a network stack is NOT hardware. Port what maps; for the rest, document why it stays in Rust. Do NOT fake it.

## READ THE WORKED EXEMPLAR FIRST
Two modules are already ported — study them and COPY the pattern:
- `tri-net/specs/wire.t27` (from `src/wire.rs`) — the reference. iverilog-clean; **8 embedded `test` assertions pass in `vvp`**. Note how it handles T27's no-array limit: the 11-byte header is modeled with **functions** (`header_byte(fields, idx)` returns the idx-th byte via if/else-if on `idx`; `u32_be(b0..b3)` reassembles the parse side), and the `test` blocks MIRROR the Rust unit tests (roundtrip, bad-version reject). if/else-if chains where every branch `return`s DO lower correctly.
- `t27/specs/fpga/bpsk.t27` — the BPSK modulator + Barker-13 correlator (module 1).
- `tri-net/docs/T27_PORT_STATUS.md` — the honest module map; UPDATE it as you go.

## HARD feasibility scoping (read the Rust in `tri-net/src/` first, then decide)
- **PORTS to .t27** (integer / datapath / protocol logic): `wire.rs` frame header + byte packing; the modem TX (bit->+/-1 serialize, framing); ETX metric arithmetic in `routing.rs`; GF16 numeric (`gf16.rs`, mirrors t27 gf16); state-machine/counter logic in `daemon.rs`/`discovery.rs`.
- **DOES NOT port** (leave the Rust, note it in the PR + a `docs/T27_PORT_STATUS.md`): `crypto.rs` (X25519 + ChaCha20-Poly1305 + HKDF — bignum field arithmetic + AEAD, enormous/infeasible in a spec-first HW language); the modem RX **float DSP** (RRC / timing / CFO in `modem.rs` — T27 has no floats); async UDP/TUN I/O (no I/O runtime in T27). Array-backed tables need array/RAM lowering (blocked on t27#1258).

## Order (wire + bpsk already DONE — continue from here)
1. ~~`specs/wire.t27` (frame header)~~ ✅ DONE — use as the exemplar.
2. `specs/etx.t27` — the ETX / WMEWMA delivery-ratio metric math from `src/routing.rs` (integer/fixed-point: clamp, ratio update, DEAD_EPS threshold). Model the fixed-point ratio as an integer scaled by e.g. 1000; mirror the Rust routing tests. NOTE the dynamic neighbor TABLE needs array/RAM lowering (blocked on t27#1258) — port only the scalar metric math for now, flag the table.
3. `specs/gf16_ofdm.t27` — the GF16 OFDM numeric pieces from `src/gf16.rs` (compare to `t27/specs/numeric/gf16.t27`).
4. `specs/modem_tx.t27` — TX framing on top of bpsk (length byte + payload serialization), reusing the wire.t27 byte-modeling pattern.
5. `daemon`/`discovery` state machines (FSM/counters only; no I/O). Assess `crypto.rs` + the modem RX float-DSP LAST — expect to flag them NOT-PORTABLE in `T27_PORT_STATUS.md`.

## Per-module loop
1. Read the Rust module in `tri-net/src/<m>.rs`; identify the pure integer/logic core (ignore I/O, floats, crypto bignum).
2. Write `tri-net/specs/<m>.t27`: `module`, `const`, scalar `var`, `fn` (if/ELSE single-assignment, flat bodies, named blocks, no array-const tables — pack into scalars), plus `test`/`invariant` blocks that MIRROR the Rust unit tests (L4).
3. Validate — the PROVEN command sequence (same as wire.t27):
   ```bash
   ( cd /Users/ssdm4/Desktop/PROJECTS/CLAUDE/t27 && cargo build --release -p t27c )   # once
   T=/Users/ssdm4/Desktop/PROJECTS/CLAUDE/t27/target/release/t27c
   M=tri-net/specs/<m>.t27; MOD=<ModuleName>   # e.g. MeshWire
   $T parse "$M" && $T typecheck "$M"
   $T gen-verilog "$M" > /tmp/m.v
   grep -c TODO /tmp/m.v            # must be 0
   iverilog -t null /tmp/m.v        # must be 0 errors
   # simulate the embedded test blocks (they run when the module is instantiated):
   printf '`timescale 1ns/1ps\nmodule tb; reg clk=0,rst_n=1,en=1; wire ready; %s dut(.clk(clk),.rst_n(rst_n),.en(en),.ready(ready)); initial #2 $finish; endmodule\n' "$MOD" > /tmp/tb.v
   iverilog -o /tmp/sim /tmp/m.v /tmp/tb.v && vvp /tmp/sim | grep -iE "PASSED|FAILED"   # ALL PASSED, 0 FAILED
   ( cd tri-net && $T seal specs/<m>.t27 --save )   # writes .trinity/seals/specs_<ModuleName>.json
   ```
   **Proof a module is correctly ported = every `.t27` `test` assertion PASSES in `vvp`**, matching the Rust module's tests. Commit the spec + its seal + the updated `docs/T27_PORT_STATUS.md`.
4. Keep the Rust in place until the port is validated. Commit small (`Refs #16`). Update `docs/T27_PORT_STATUS.md` (a table: module -> ported / partial / not-portable + why).
5. Open a PR to `gHashTag/tri-net` `main`.

## Definition of done (per the incremental goal)
Each portable module has a validated `.t27` spec (iverilog-clean, its tests simulate green); `docs/T27_PORT_STATUS.md` honestly records what ported and what stayed Rust (crypto, float DSP, I/O) with reasons. Do NOT claim the whole stack is "on T27" — only the hardware-mappable parts are.

## Guardrails
- Honesty over completeness: if a module is mostly non-hardware, port only its integer core and SAY SO; don't emit meaningless RTL (see the `t27-fpga-spec` skill's "don't chase non-datapath specs").
- ASCII-only (L3); every spec has a `test`/`invariant` (L4). Small reviewable PRs. `t27c` is a TOOL from the `CLAUDE/t27` repo; the mesh specs live in `tri-net/specs/`.
- If blocked (e.g. array tables need t27#1258, or a construct won't lower), STOP, commit what's safe, and report on #16 — don't force it.
