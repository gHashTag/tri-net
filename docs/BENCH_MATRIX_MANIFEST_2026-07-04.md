# Bench Matrix Manifest — 2026-07-04

**Branch:** `feat/strategic-audit-2026-07-04` @ `fa4702e`
**Compiler:** t27c from `gHashTag/t27@3c912d9` (ExprCast lowered in all 4 backends)
**Gate:** `cargo test --all` = 141 passed, 0 failed

## Flipped specs (27/67 = 40.3%)

| # | Spec | Layer | gen/rust (L) | gen/zig (L) | gen/c (L) |
|---|---|---|---|---|---|
| 1 | wire.t27 | framing | 63 | 73 | 128 |
| 2 | hello.t27 | discovery | 67 | 108 | 154 |
| 3 | etx.t27 | routing | 68 | 101 | 145 |
| 4 | crc16.t27 | utility | 27 | 55 | 95 |
| 5 | byte_utils.t27 | utility | 51 | 63 | 100 |
| 6 | mesh_routing.t27 | routing | 34 | 123 | 175 |
| 7 | key_management.t27 | crypto | 179 | 204 | 271 |
| 8 | frame_buffer.t27 | transport | 27 | 66 | 109 |
| 9 | packet_queue.t27 | transport | 45 | 94 | 145 |
| 10 | congestion_control.t27 | transport | 183 | 154 | 214 |
| 11 | flow_control.t27 | transport | 186 | 151 | 225 |
| 12 | self_healing.t27 | resilience | 114 | 200 | 292 |
| 13 | trust_manager.t27 | trust | 80 | 66 | 112 |
| 14 | timer.t27 | timing | 33 | 78 | 118 |
| 15 | transport_tx_fsm.t27 | transport | 147 | 185 | 238 |
| 16 | redundancy_management.t27 | resilience | 186 | 223 | 297 |
| 17 | fault_detection.t27 | resilience | 133 | 193 | 272 |
| 18 | lite_crypto.t27 | crypto | 27 | 86 | 135 |
| 19 | network_metrics.t27 | network | 38 | 63 | 106 |
| 20 | m3_multihop.t27 | network | 49 | 43 | 87 |
| 21 | link_statistics.t27 | network | 23 | 46 | 81 |
| 22 | access_control.t27 | optimization | 109 | 162 | 240 |
| 23 | bandwidth_allocator.t27 | optimization | 186 | 245 | 325 |
| 24 | cache_management.t27 | optimization | 219 | 191 | 267 |
| 25 | compression_engine.t27 | optimization | 242 | 200 | 260 |
| 26 | cross_layer_optimizer.t27 | optimization | 111 | 189 | 265 |
| 27 | energy_aware_routing.t27 | optimization | 177 | 217 | 294 |

**Totals:** 27 specs × 3 backends = 81 gen files, 81 drift checks.
**All CLEAN:** 0 `return ()`, 0 `unsupported`, 0 compile errors.

## Layer coverage (11 layers)

| Layer | Specs | Count |
|---|---|---|
| framing | wire | 1 |
| discovery | hello | 1 |
| routing | etx, mesh_routing | 2 |
| crypto | key_management, lite_crypto | 2 |
| utility | crc16, byte_utils | 2 |
| transport | frame_buffer, packet_queue, congestion_control, flow_control, transport_tx_fsm | 5 |
| resilience | self_healing, redundancy_management, fault_detection | 3 |
| trust | trust_manager | 1 |
| timing | timer | 1 |
| network | network_metrics, m3_multihop, link_statistics | 3 |
| optimization | access_control, bandwidth_allocator, cache_management, compression_engine, cross_layer_optimizer, energy_aware_routing | 6 |

## Deferred (4 specs — NOT t27c limitations)

| Spec | Reason | Fix |
|---|---|---|
| adaptive_retry | `let mut` (imperative accumulator) | Rewrite to pure-function recursion |
| link_quality_monitor | `let` + `::` module-path calls | Rewrite to top-level functions |
| multipath_router | `let mut best_idx` (imperative search) | Rewrite to expression form |
| auto_config | Compile error (syntax) | Investigate + fix spec syntax |

**Root cause:** t27 is a pure-functional hardware-datapath language; `let mut` (mutable bindings) is not in the grammar. 13 clean specs use `let` (immutable) extensively — `mut` is the sole differentiator. This is an empirical finding, not a language bug.

## Drift-guard configuration

**Workflow:** `.github/workflows/spec-drift-guard.yml`
**Mechanism:** CI rebuilds t27c from `gHashTag/t27@master`, regenerates all 27 specs × 3 backends, diffs against committed gen files. Any mismatch = CI failure.
**Loop:** `for spec in wire hello etx crc16 byte_utils mesh_routing key_management frame_buffer packet_queue congestion_control flow_control self_healing trust_manager timer transport_tx_fsm redundancy_management fault_detection lite_crypto network_metrics m3_multihop link_statistics access_control bandwidth_allocator cache_management compression_engine cross_layer_optimizer energy_aware_routing`

---

φ² + φ⁻² = 3
