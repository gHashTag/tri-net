# TRI-NET Verifiable Ternary Compute over an A2A Mesh

Canonical design reference for the compute-receipt / A2A-over-mesh / ternary
verification ring. Consolidates the spec-first work landed across PRs #102-#122.
Every value below is a re-checked known-answer test (KAT); the boundaries section
states exactly what is proven, and where.

## 1. Problem

Agents host a GoldenFloat compute skill (GF-T, ternary-native) and answer tasks over
the mesh. A peer that pays for a result must be able to confirm -- without trusting
the executor -- that the result is (a) over the requested inputs, (b) correct, (c)
produced by the claimed executor, and (d) not a replay. TRI-NET makes a compute
receipt verifiable along all four axes, plus a scalable optimistic path.

## 2. The ring (core -> outward)

Each layer is one or more `.t27` specs -> `t27c gen-rust` -> composed in a thin `src/bin`
harness. `t27` has no cross-module calls, so multi-spec composition lives in the bins;
all logic is generated from specs.

```
                    input           compute           output
  operands --SHA256--> in_hash --> GF-T recompute --> result
      |                   |              |               |
      +--- input_digest (256-bit, input_digest_pre) -----+
                          |
             Ed25519 sign(digest) + identity(pubkey)   ... WHO
                          |
             Merkle batch root (merkle_pair_pre)        ... MEMBERSHIP
                          |
             256-bit ledger head (ledger_entry_pre)     ... STATE
                          |
        freshness (is_fresh) + settle / challenge+slash / optimistic lifecycle
```

### 2.1 Crypto core -- `tri_sha256`, `tri_compute_receipt`
- `sha256_compress(state, block)` (PR #105) makes SHA-256 **multi-block** (arbitrary
  chaining state), so blocks compose; `sha256_word` = `compress(IV, ...)`. Regression:
  the NIST "abc" vector still passes.
- `digest_pre` / `ledger_entry_pre` / `merkle_pair_pre` / `input_digest_pre` are
  canonical single- or two-block SHA-256 preimages. The 256-bit commitments:

  | commitment | preimage | KAT (word0..1 .. word7) |
  |---|---|---|
  | receipt digest | `digest_pre` (TAG "TRCP" + 8 fields) | `14e71587 4fd6b3ae .. 25b7b544` |
  | ledger head | `ledger_entry_pre` (prev256 || digest256 || balance || epoch, 2 blocks) | `73c15740 e149d4e2 .. 3a8d3244` |
  | merkle root (4 leaves) | `merkle_pair_pre` (H(l||r), 2 blocks) | `5c88e07a f6c1a41c .. 489c3155` |
  | input digest | `input_digest_pre` (TAG "TRIB" + operand_hash256 + fields, 2 blocks) | `adeacb9e 1a2a3fad .. 5333e1c1` |

  Each is **bit-exact vs an independent `hashlib` SHA-256**.

### 2.2 Ternary compute -- `tri_gft_ladder`, `tri_gft_arith`, `tri_gft_add`, `tri_gft_sub`
The GF-T16 value is `(1 + M/512) * 2^e`, `[sign | 4 balanced-ternary exp trits | 9
mantissa bits]` (t27 `specs/numeric/gft16.t27`). A verifier recomputes:
- **multiply** (`gft_mul_offset_full` + `gft_mul_mant`): exponent add with the mantissa
  renormalization carry. Exhaustive over 81x81 exponent offsets and 512x512 mantissa
  pairs vs an integer oracle.
- **add** (`gft_add`, same sign): align + add + one-carry renorm. 86,436 cases vs a
  float oracle.
- **subtract** (`gft_sub`, different sign): full-precision difference + variable
  leading-zero renormalization (fixed if-ladder, round toward zero). **35,046,400**
  cases over ALL offset pairs 0..79 vs an exact i128 round-toward-zero oracle (a float
  oracle is insufficient here -- round-to-nearest loses the sub-ULP operand).
- **ladder** (`tri_gft_ladder`): exponent trits `Et = 2/3/4/6` for GF-T4/8/16/32, so
  `gft_offset_max(Et)=3^Et-1` = 8/26/80/728 and `gft_bias(Et)=(3^Et-1)/2` = 4/13/40/364,
  with `gft_mant_bits` = 1/4/9/25; `is_finite_gft_n` by the ternary rule.
- **all rungs, not just GF-T16**: the multiply/add/subtract above are parametric (`_p`
  fns take the rung's `mant_one`/`offset_max`), so GF-T4/8/16 recompute in u32 and
  GF-T32 (25-bit mantissa) in u64. `trinet_a2a_node.compute_ok` selects the rung by
  `width_to_et` and verifies a result under its own geometry -- all four rungs
  end-to-end, each validated against its exact integer oracle.

### 2.3 Identity & signature -- `tri_node_identity`
`executor_id = SHA-256(Ed25519 pubkey)[0..4]`; `who_ok` needs a valid signature AND
`executor == commitment(signer key)` -- a node cannot sign with its own key and claim
another executor. `executor_id` is bit-exact vs the `sha2` crate.

### 2.4 A2A routing -- `tri_a2a`, `tri_a2a_wire`, `tri_a2a_card`
Demux by PORT on sealed datagrams (never a magic byte). `tri_a2a_wire` fixes the
signed-result and operand layouts (`operand_pre`, `SIG_LEN`). `tri_a2a_card` advertises
`(family, width, op)`, so `can_serve_op` routes a task only to a capable host.
`is_fresh` / `next_watermark` gate anti-replay.

### 2.5 Settlement & economics -- `tri_compute_settle`, `_challenge`, `_bond`, `_optimistic`
Two verification modes:
- **Pessimistic** (`trinet_a2a_node`): the endpoint enforces, before paying,
  freshness (anti-replay) + WHO (Ed25519) + 256-bit input binding + CORRECTNESS
  (recompute) + membership. A forged, mis-computed, replayed, or wrong-operand result
  earns nothing.
- **Optimistic** (`tri_compute_optimistic`): a bonded receipt is credited
  provisionally; a challenge window opens; a successful recompute-backed challenge
  (`tri_compute_challenge.resolve`) REVERSES the credit and slashes the bond
  (`tri_compute_bond`), rewarding the challenger; unchallenged receipts FINALIZE.
  The compute analogue of an optimistic rollup.

## 3. Harness binaries (proofs)

| bin | proves |
|---|---|
| `trinet_receipt_digest` | 256-bit receipt digest bit-exact vs hashlib |
| `trinet_ledger_head` / `trinet_ledger_chain` | 2-block ledger head; head commits the balance |
| `trinet_merkle_batch` | 256-bit Merkle root + inclusion proofs; one signature, N receipts |
| `trinet_input_digest` | 256-bit input commitment (~2^128, not the 32-bit `in_hash`) |
| `trinet_settle_signed` / `trinet_receipt_verify` | signature gate; accept iff sig+membership+compute |
| `trinet_compute_verify` | op-dispatch: MUL/ADD/subtract each verified by its own recompute |
| `trinet_node_identity` / `trinet_requester_verify` | identity binding; requester round-trip verify |
| `trinet_a2a_node` | the composed endpoint: freshness + WHO + input(256) + correctness + membership |
| `trinet_challenge` / `trinet_optimistic_settle` | challenge/slash; optimistic finalize/reverse lifecycle |
| `trinet_compute_over_mesh` | the receipt actually crosses the wire: both legs (assign + result) sealed with real ChaCha20-Poly1305, blind relay, WHO+input+recompute+freshness gate, 5 adversarial negatives |
| `trinet_batch_over_mesh` | throughput: ONE signature over a 256-bit Merkle root settles N receipts by O(log N) inclusion over the wire; a receipt not under the root is isolated, a wrong signer fails WHO |
| `trinet_ledger_over_mesh` | auditable settled-balance history: R rounds chained into a 256-bit ledger head; the verifier recomputes the chain from the received rounds; rewriting any past round diverges the head |
| `trinet_challenge_over_mesh` | optimistic fraud-proof over the wire: a challenger opens a sealed bonded claim, INDEPENDENTLY recomputes, and slashes+reverses fraud (bond→0, credit clawed back) while an honest claim is kept |
| `trinet_ratchet_over_mesh` | multi-hop blind relay + forward secrecy: 2 blind hops, then an HKDF-SHA256 key ratchet (should_ratchet@2^20, must_reject@2^24) where each epoch key opens ONLY its epoch |
| `trinet_discovery_over_mesh` | discovery/matchmaking: a host advertises a signed capability card, the requester routes a task ONLY if can_serve_skill_op holds; unadvertised family/width/op and a forged card are all rejected |
| `trinet_lifecycle_over_mesh` | the layers COMPOSE: one sealed flow chains discovery -> compute -> batch -> ledger, each stage's output feeding the next (balance 1000 -> 1032) |
| `trinet_gft32_over_mesh` | the LARGEST rung crosses the wire: a GF-T32 (25-bit mantissa, u64) task is sealed with full-u32 operand words (assign_mant's 16-bit packing cannot), recomputed via the u64 path, WHO+input-bound -- so all four rungs verify end-to-end over the mesh, not just in-process |

## 4. Boundaries (what is proven, and where)

- **Structure**: every spec passes `t27c typecheck` (0 errors) and `gen-rust`. This
  runs in CI (`ci.yml`: fmt/clippy/build/test) for the library.
- **Behavior**: proven **locally** by the harness bins -- bit-exact KATs vs `hashlib`
  / the `sha2` crate / exact i128 / float oracles, and a real `ed25519-dalek`
  signature. **This is NOT reproduced in CI.** `ci.yml` runs `cargo build/test`
  WITHOUT `t27c`, so `build.rs` skips gen regeneration and builds against the committed
  (stale) `gen/`; the spec `test` blocks are not executed by `t27c`; and `autobins =
  false` leaves the harness bins unbuilt. Declaring them would fail CI against stale
  gen, and the `no-gen-edits` hook forbids committing fresh gen -- the documented,
  unresolvable-from-inside contradiction (also why `spec-drift-guard` is chronically
  red on `main`). Behavioral reproduction therefore requires a local checkout with the
  sibling `t27` repo (see section 5).
- **Transport**: exercised, not just framed. `trinet_compute_over_mesh` seals both legs
  of the A2A exchange with a real `chacha20poly1305` AEAD under a `crypto_frame` nonce
  (the 12-byte `epoch||counter` header as associated data); a blind relay forwards
  ciphertext only; the far end opens byte-exact and settles under the same
  WHO+input+recompute+freshness gate. Five adversarial negatives reject a tampered
  assign, a tampered result, a replayed counter, an operand-swapped receipt, and an
  identity-swapped receipt (valid signature, unheld executor id). Keys are fixed KATs
  here; the authenticated key agreement is the mesh handshake (trios-mesh), out of scope.
  The over-wire suite grows core->outward on the same sealed transport: `_batch_` (one
  signature over a Merkle root settles N receipts by inclusion), `_ledger_` (rounds
  chained into a tamper-evident audited head), `_challenge_` (an optimistic fraud-proof
  where the challenger recomputes and slashes), `_ratchet_` (multi-hop blind relay +
  a real HKDF-SHA256 forward-secret key ratchet, exercising `should_ratchet`/`must_reject`),
  and `_discovery_` (a requester routes a task only to a host whose signed capability card
  advertises the skill). `trinet_lifecycle_over_mesh` then proves the layers COMPOSE:
  discovery -> compute -> batch -> ledger in one sealed flow, each stage feeding the next.
- **Silicon**: **RTL built and synthesized; not yet run on a board.** `fpga/gft/`
  now realizes the GF-T ALU -- `gft_mul` / `gft_add` / `gft_sub` (mul/add/sub) plus a
  4-lane MAC (`gft_dot4`, narrowed to `gft_dot4_tile` = 4 DSP48E1) -- as synthesizable
  Verilog from the SAME `tri_gft_arith`/`tri_gft_add`/`tri_gft_sub` specs the over-wire
  verifier runs. Every module passes an `iverilog` KAT against the exact values the
  verifier accepts, and `yosys synth_xilinx` cleanly (`gft_alu_ax7203` is the AX7203
  board top with an on-chip self-check whose fail path is proven). What has NOT happened:
  no bitstream has been placed-and-routed or flashed, so **no GF-T recompute has run on
  real silicon yet**. That is the one remaining step -- `nextpnr-xilinx` P&R + AL321 flash
  on the AX7203 (`docs/../fpga/gft/RUN_ON_SILICON.md`), which needs the board/openXC7
  container. The `t27c gen-verilog` interleaved-reg defect is now FIXED upstream:
  `gft_arith_gen_kat_tb.v` shows the GENERATED GF-T Verilog matches the over-wire
  verifier's exact values, so one `.t27` provably drives both the Rust A2A verifier and
  synthesizable Verilog. `fpga/gft/*.v` remain hand-shaped I/O datapaths (the generated
  module is a function library); both are KAT-gated against the same over-wire values.
- **Coverage**: GF-T arithmetic recompute now spans **all four rungs** -- GF-T4/8/16
  (u32) and GF-T32 (u64) -- for multiply, add, and subtract, each validated against its
  exact integer oracle and wired into `trinet_a2a_node.compute_ok` (rung selected by
  `width_to_et`). The exhaustive case counts quoted in section 2.2 are the GF-T16
  sweeps; the other rungs are validated over representative-plus-boundary oracles, not
  the full GF-T16-scale exhaustion. All four rungs also verify **over the sealed wire**:
  GF-T16 via the u32 exchange and GF-T32 via `trinet_gft32_over_mesh` (full-u32 operand
  words + the u64 recompute), so rung coverage is end-to-end, not only in-process.

## 5. Reproduce a proof locally

Requires the sibling `t27` repo (`../t27`) built (`t27c`). From the tri-net checkout:

```bash
cargo run --release --bin trinet_receipt_digest   # 256-bit receipt digest vs hashlib
cargo run --release --bin trinet_a2a_node         # the composed hardened endpoint
cargo run --release --bin trinet_optimistic_settle # optimistic finalize/reverse lifecycle
cargo run --release --bin trinet_compute_over_mesh # receipt across a real sealed A2A datagram
cargo run --release --bin trinet_batch_over_mesh   # one signature settles N receipts by inclusion
cargo run --release --bin trinet_ledger_over_mesh  # auditable settled-balance head across rounds
cargo run --release --bin trinet_challenge_over_mesh # optimistic fraud-proof: recompute and slash
cargo run --release --bin trinet_ratchet_over_mesh # multi-hop blind relay + forward-secret ratchet
cargo run --release --bin trinet_discovery_over_mesh # capability-advertised routing (signed cards)
cargo run --release --bin trinet_lifecycle_over_mesh # discovery -> compute -> batch -> ledger, composed
```

(Run in `--release`: the generated hash uses wrapping arithmetic; a debug build panics
on the intended mod-2^32 overflow -- the known R7 gen-rust wrapping-ops defect.)

## 6. Positioning

Verifiable-inference / DePIN systems (VeriLLM, TOPLOC/INTELLECT, Keryx OPoI, HadAgent,
Truebit) commit task results with 256-bit hashes / Merkle roots, bind input hashes,
and use optimistic challenge + slashing. TRI-NET mirrors that stack, specialized to a
**ternary-native GoldenFloat** workload whose result a verifier can cheaply recompute,
authored spec-first in `.t27`.
