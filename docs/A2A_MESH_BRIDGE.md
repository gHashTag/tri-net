# A2A ↔ mesh bridge — design contract (grounded in the real types)

The paper's remaining connective gap (§8.3): carry a Google-A2A-shaped agent conversation over the
tri-net sealed mesh, with results that are *verifiable* (bound + correct), not merely delivered.
This is the design; the two type worlds it joins both exist and were read directly.

## The two sides (as they actually are)

**trios-a2a** (`gHashTag/trios`, `crates/trios-a2a`, rings SR-00..04 + BR-OUTPUT):
- `AgentId(String)`, `AgentCard { id, name, capabilities: Vec<Capability>, status }`, `Capability`,
  `AgentStatus` — SR-00 (identity/discovery).
- `A2AMessage { id, from: AgentId, to: AgentId, msg_type, payload: serde_json::Value, timestamp }`;
  `A2AMessageType { Direct, Broadcast, TaskAssign, TaskUpdate, TaskResult, AddToolCall, Heartbeat,
  Error }`; `Task { id, title, description, assigned_to, created_by, state, priority, … }` — SR-01.
- `A2ARegistry` (SR-02), `A2ARouter` (BR-OUTPUT), `SqliteA2AStore` (SR-04). JSON/serde transport.

**tri-net mesh** (this repo + trios-mesh): `crypto_frame` (ChaCha20-Poly1305 AEAD, nonce/replay,
HKDF ratchet), `tri_a2a` (demux-by-port, assign↔result binding, freshness), `tri_node_identity`
(executor = SHA-256(pubkey)), `tri_compute_receipt` (bind {executor, task, input_hash, output,
epoch} → SHA-256 → Ed25519), `tri_compute_challenge` (recompute `gft_mul`, slash a wrong result).

## Mapping (the contract)

| A2A concept | mesh realization | proven by |
|-------------|------------------|-----------|
| `A2AMessage` (JSON) | plaintext of ONE sealed `crypto_frame` (AEAD) → confidential + authentic on-air | crypto_frame ring |
| `A2AMessage.from/to: AgentId` | bound to `tri_node_identity` executor = SHA-256(pubkey); `to` = mesh route / broadcast | who_ok / WHO |
| `AgentCard` + `Capability` | signed capability card; requester routes only to an advertised skill | `_discovery_` bin |
| `TaskAssign` | `tri_a2a` assignment leaf (assign↔result binding, freshness/anti-replay) | tri_a2a ring |
| `TaskResult` | **carries a `tri_compute_receipt`**: output bound to input_hash + task id + executor | `gft_receipt_binding` |
| a *wrong* `TaskResult` | challenger recomputes (e.g. `gft_mul`) and **slashes** the executor | `gft_compute_challenge` |
| `Task.state` transitions | ledger-chained (`tri_ledger` head), optimistic finality window | lifecycle_over_mesh |

## The one new seam to build (the bridge crate)

A thin adapter, `trios-a2a-mesh` (in the `trios` workspace, NOT tri-net — this doc is the contract
it implements):

1. **encode**: `A2AMessage` → canonical bytes → seal via mesh session key → `crypto_frame`. `to`
   selects the mesh route (or broadcast sentinel).
2. **decode**: `crypto_frame` open → verify sender identity == `A2AMessage.from` → deliver.
3. **receipt hook**: when `msg_type == TaskResult`, attach/verify a `tri_compute_receipt` over
   `(input_hash = H(A2AMessage of the matching TaskAssign.payload), output = payload, task = id)`.
   Reject a TaskResult whose receipt does not verify — a forged result cannot ride a real assign.
4. **challenge hook**: optionally recompute the ternary op (the receipt names the operands) and
   slash on mismatch, exactly as `gft_compute_challenge` proves in-repo.

## What is proven vs pending

- **Proven in tri-net** (this repo): every mesh-side piece the mapping leans on — sealing, identity
  binding, discovery routing, receipt binding, recompute-and-slash. See `docs/GF_T_PROVEN.md` #6/#7.
- **Pending**: the adapter crate itself, which must be built and tested in the `trios` workspace
  (cross-repo; the trios repo clones blobless+sparse but is not built here). This doc is the
  contract it implements so the seam is unambiguous when that work starts.
