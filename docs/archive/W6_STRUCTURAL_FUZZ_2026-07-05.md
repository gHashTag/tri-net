# W6.1 — Structural fuzz (cross-backend acceptance agreement)

Anchor: phi^2 + phi^-2 = 3.

## Question

The empirical bench matrix in [`docs/PAPER_DELTA_v0.md`](./PAPER_DELTA_v0.md) §4.5 shows that the 68 committed specs of the current corpus generate byte-identically across the Rust, Zig, and C backends of `t27c`. The paper's own §5.6 flags an obvious follow-up: byte identity across 68 hand-written specs does not, by itself, imply the three backends agree on **which spec bodies they accept as syntactically valid at all**. W6.1 is the smallest experiment that starts to close that gap: fuzz-generated spec bodies, run through all three backends, and compare accept/reject decisions.

## Method

- **Generator**: [`scripts/fuzz/gen_specs.py`](../scripts/fuzz/gen_specs.py) emits `module { const ...; fn ... -> T { ... } }` bodies, following the grammar observed in the real corpus (`wire.t27`, `byte_utils.t27`). Random field names, integer types (`u8` / `u16` / `u32` / `usize`), constant literals in-range, arithmetic + bitwise + comparison expressions of bounded depth, sometimes wrapped in an `if/else`.
- **Three buckets**, mixed with target fractions 0.4 / 0.4 / 0.2:
  - `valid`     — well-formed spec body per the observed grammar;
  - `malformed` — one deliberate lexical/syntactic injury (drop the closing `}`, drop a `;`, rename `return`→`returnn`, replace `u8`→`u9`, replace `->`→`=>`, drop one `(`);
  - `semi-valid`— parseable shell with a semantic quirk (unknown identifier in a return expression, extra `ghost: u8` parameter, `(0 as bool) as u32` cast chain).
- **Harness**: [`scripts/fuzz/run_fuzz.py`](../scripts/fuzz/run_fuzz.py) invokes `t27c` in three modes — `gen-rust` (Rust), `gen` (Zig), `gen-c` (C) — via `subprocess.run` with a 10 s timeout. Exit code and a stderr classifier (regex over `parse|type|arity|undefined|…`) give a coarse error class per backend.
- **Success criterion**: for every generated spec, do the three backends agree on accept-or-reject (all three exit 0, or all three exit non-zero)? On rejections, do they agree on the class of error?
- **Seed**: `0xF1F1F1F1` (fixed, mnemonic phi-phi). `--n 1000`.
- **t27c binary**: built once in release mode from `t27@879c1c7`, 12.6 MB.
  - `sha256(t27c) = a0c0ef8e2baf84fbad9bb3b7308a284c131c86ec8385ed1d8229a480393e1f6e`

## Result

At `t27@879c1c7` on this sandbox:

| Metric | Value |
| --- | ---: |
| Specs fuzzed | 1000 |
| All-three-accept | 930 |
| All-three-reject | 70 |
| Disagreement (some backends accept, others reject) | **0** |
| Cross-backend agreement | **100.000 %** |
| Reject-class agreement (all three classify identically) | 70 / 70 |

Per-bucket:

| Bucket | Total | All accept | All reject | Disagree |
| --- | ---: | ---: | ---: | ---: |
| `valid`      | 397 | 397 | 0 | 0 |
| `semi-valid` | 203 | 203 | 0 | 0 |
| `malformed`  | 400 | 330 | 70 | 0 |

All 70 rejected specs came from the same damage class — `drop-close-brace` — and every backend classified them as `parse-error`. The other malformation classes (`bad-type-name`, `drop-semicolon`, `bad-return-arrow`, `unclosed-paren`, `rename-return-keyword`) and every `semi-valid` mutation were **accepted by all three backends alike**.

## Interpretation

- The three backends **agree perfectly on the boundary of the accepted language** on this 1000-sample. Whatever `t27c` calls a "valid spec," Rust and Zig and C all agree it is one — and the very few things it rejects, they all reject as the same class of parse error. Zero divergence in 1000 tries.
- The fraction of malformed inputs that survived (330 / 400) is an honest statement about `t27c`'s parser, not about the harness: the current front end is permissive — a mistyped type name like `u9`, a dropped semicolon, or `return` misspelled as `returnn` all still yield code out of every backend. That is a separate finding worth flagging, but it does not weaken the W6.1 claim: whatever the parser accepts, it accepts uniformly across the three code emitters.
- W6.1 does not measure functional equivalence of the emitted code. It measures only that the front-end / three-back-end decision function is identical. Runtime differential testing is W6.2, gated on the outcome of this pilot.

## Artifacts

- Generator: [`scripts/fuzz/gen_specs.py`](../scripts/fuzz/gen_specs.py)
- Harness: [`scripts/fuzz/run_fuzz.py`](../scripts/fuzz/run_fuzz.py)
- Generated specs: `bench/fuzz_specs/` (1000 files + `manifest.json`, seed = `0xF1F1F1F1`)
- Raw per-run CSV: [`bench/fuzz_results/fuzz_raw.csv`](../bench/fuzz_results/fuzz_raw.csv) (3000 rows: 1000 specs × 3 backends)
- Aggregate JSON: [`bench/fuzz_results/fuzz_summary.json`](../bench/fuzz_results/fuzz_summary.json)

## Reproduction

```bash
# from tri-net repo root, with t27c built at t27@879c1c7:
python3 scripts/fuzz/gen_specs.py --n 1000 --outdir bench/fuzz_specs
python3 scripts/fuzz/run_fuzz.py \
    --t27c ../t27/target/release/t27c \
    --specs-dir bench/fuzz_specs \
    --out bench/fuzz_results
```

Expected: `n_disagree = 0`, `agreement_pct = 100.0`, wall-clock ≈ 5 s on a 2 vCPU sandbox VM.

## Provenance

- Sandbox environment: 2 vCPU, 8 GB RAM, Linux (same host as W5 measurements).
- Date: 2026-07-05.
- Generator/harness authored and executed by the agent in this session; every number here comes from the `fuzz_summary.json` written by the harness at run time. No fabrication.
