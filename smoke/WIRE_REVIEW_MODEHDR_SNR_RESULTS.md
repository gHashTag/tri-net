# Adversarial Review — Mode Header + HELLO SNR Wire Code — Results (2026-07-08)

**Component:** `trios-mesh` `src/modem.rs`, `src/discovery.rs`
**Reviewed:** iter20–21 wire code (per-frame mode header + Hello SNR feedback)
**Fix commit:** `61dc8af`
**Method:** 9-agent adversarial-review workflow (find → independently verify each
finding by building the exact repro against the real code). 5 findings confirmed.

## Findings and disposition

| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| 1 | MED | Mode codepoints `0`/`1` are Hamming-distance 1 → a single mode-LSB symbol error silently swaps BPSK↔QPSK, returning wrong bytes **and** a wrong `was_qpsk` flag (consumed by adaptive MCS) instead of rejecting | **Fixed** |
| 2 | LOW | The 8 mode symbols are unprotected → any error in the 7 unused high bits drops the whole frame, making the auto path strictly less robust than fixed-mode reception | **Fixed** (same change) |
| 3 | HIGH | `Hello::parse` used `>=` with no exact-length check → an old-format beacon carrying NO SNR that arrives with ≥ n stray trailing bytes (padded/reused recv buffer, radio framing, appended bytes) is reinterpreted as SNR, fabricating a far-end estimate that drives MCS | **Fixed** |
| 4 | MED | `parse` silently ignores trailing bytes beyond the SNR block instead of rejecting | **Fixed** (same change) |
| 5 | MED | `to_bytes` silently drops the whole SNR vector when `snr.len() != heard.len()` | **Won't-fix** (see below) |

## Fixes

**Mode header → 8× repetition code (findings #1, #2).** Recode the two modes as
the maximally-separated bytes `MODE_BPSK = 0x00` / `MODE_QPSK = 0xFF` (Hamming
distance 8) and majority-vote the 8 mode symbols via `canonical_mode()`:
0..3 set bits → BPSK, 5..8 → QPSK, a 4-4 tie → reject. The header now **corrects
up to 3 symbol errors** and a single error can never swap the mode. The most
fragile field of an auto frame becomes the most robust, at zero wire-size cost
(the 8 mode symbols already existed).

**Exact-length HELLO parse (findings #3, #4).** Require the buffer to be exactly
`base = 9 + 4n` bytes (no SNR) or `base + n` bytes (one SNR byte per neighbor);
reject everything else. Arbitrary padding can no longer fabricate SNR. The one
irreducible case — `extra == n` bytes appended to an old-format frame is
byte-identical to a new-format frame — is documented and acceptable: HELLO is an
**unauthenticated discovery beacon**, so SNR is then exactly as robust as
`src`/`seq`/`heard` (all corruptible with no integrity field), and an active
attacker who can forge a beacon already sets SNR freely via a well-formed frame.
No new attack surface is introduced; the accidental corruption path is closed.

**#5 won't-fix (documented).** `to_bytes` emitting a valid old-format frame when
`snr.len() != heard.len()` is a **safe degradation**, not data corruption, and is
unreachable via the actual API: the sole caller (`trios_radiod`) builds `snr` by
mapping over the same `heard` vector, and `Hello::with_snr` debug-asserts equal
lengths. Emitting a valid shorter frame is strictly safer than emitting one that
claims n SNR bytes it does not have.

## Verification

- New tests lock in each fix:
  `modem::mode_header_is_a_repetition_code_no_single_error_swaps_mode`,
  `discovery::trailing_bytes_on_old_format_do_not_fabricate_snr`,
  `discovery::trailing_bytes_beyond_snr_block_are_rejected`.
- `cargo test`: **226 passed, 0 failed**. `cargo build --release`: clean (the one
  pre-existing `unused_mut` warning in `src/conv.rs` is untouched, not from this
  change).

## Takeaway

Two of five confirmed findings were real correctness bugs on the new adaptive-MCS
wire path (one HIGH: fabricated SNR driving modulation choice; one MEDIUM: a
single symbol error silently swapping modulation and poisoning the MCS feedback
signal). Both are now fixed and regression-locked. This is the third adversarial
review of new wire-format code in this project to surface real defects
(iter13 RS: 8, iter14 multi-block: 5, here: 4) — the pattern holds: **new binary
framing gets reviewed before it is trusted on the air.**
