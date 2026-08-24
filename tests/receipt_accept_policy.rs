//! receipt_accept_policy -- a CI-executed guard for the receipt ACCEPTANCE POLICY, the capstone that
//! ties the ring's three independent checks into one verdict: WHO (Ed25519 sig), MEMBERSHIP (Merkle
//! batch), CORRECTNESS (GF-T recompute). specs/tri_receipt_verify.t27 fixes the policy, but its
//! assertions live only in spec `test` blocks, never compiled into `cargo test` -- so the single
//! decision that admits or rejects EVERY receipt had no CI coverage. This transcribes the policy and
//! pins it EXHAUSTIVELY over the boolean truth table, plus the op-dispatch of the correctness check.
//!
//! It also pins a subtlety worth stating: `receipt_accepted` whitelists (`== 1`) while `reject_reason`
//! blacklists (`== 0`), so the two agree ONLY on the {0,1} domain the checks actually produce. The
//! consistency test below proves they agree on every valid input; the note test documents that a
//! non-boolean would make them disagree (accept vs OK), so callers must feed 0/1.

const OK: u32 = 0;
const BAD_SIG: u32 = 1;
const NOT_IN_BATCH: u32 = 2;
const BAD_COMPUTE: u32 = 3;

const GF_OP_ADD: u32 = 0x10;
const GF_OP_MUL: u32 = 0x11;

/// Correctness check selects the recompute for the ACTUAL op (tri_receipt_verify.compute_ok_for_op).
fn compute_ok_for_op(gf_op: u32, mul_ok: u32, add_ok: u32) -> u32 {
    if gf_op == GF_OP_MUL {
        mul_ok
    } else if gf_op == GF_OP_ADD {
        add_ok
    } else {
        0
    }
}

/// Accept iff all three checks pass (tri_receipt_verify.receipt_accepted).
fn receipt_accepted(sig_ok: u32, included: u32, compute_ok: u32) -> bool {
    sig_ok == 1 && included == 1 && compute_ok == 1
}

/// First failing check, ordered who -> membership -> correctness (tri_receipt_verify.reject_reason).
fn reject_reason(sig_ok: u32, included: u32, compute_ok: u32) -> u32 {
    if sig_ok == 0 {
        BAD_SIG
    } else if included == 0 {
        NOT_IN_BATCH
    } else if compute_ok == 0 {
        BAD_COMPUTE
    } else {
        OK
    }
}

#[test]
fn acceptance_is_the_full_and_of_the_three_checks() {
    // Exhaustive over the boolean truth table: accepted iff ALL three are 1.
    for s in 0..2u32 {
        for i in 0..2u32 {
            for c in 0..2u32 {
                let expect = s == 1 && i == 1 && c == 1;
                assert_eq!(
                    receipt_accepted(s, i, c),
                    expect,
                    "accept({s},{i},{c}) must be {expect}"
                );
            }
        }
    }
    // Spot the spec's named cases.
    assert!(receipt_accepted(1, 1, 1), "all pass -> accepted");
    assert!(
        !receipt_accepted(1, 1, 0),
        "signed+included but wrong compute -> rejected"
    );
}

#[test]
fn reject_reason_names_the_first_failing_check() {
    // Ordered who -> membership -> correctness, even with multiple failures.
    assert_eq!(reject_reason(1, 1, 1), OK, "all pass -> OK");
    assert_eq!(reject_reason(0, 1, 1), BAD_SIG, "bad sig");
    assert_eq!(reject_reason(1, 0, 1), NOT_IN_BATCH, "not in batch");
    assert_eq!(reject_reason(1, 1, 0), BAD_COMPUTE, "bad compute");
    assert_eq!(reject_reason(0, 0, 0), BAD_SIG, "signature checked FIRST");
    assert_eq!(
        reject_reason(1, 0, 0),
        NOT_IN_BATCH,
        "membership before correctness"
    );
}

#[test]
fn accept_and_reason_agree_on_every_valid_input() {
    // The accept path and the diagnostic path must never disagree: accepted iff reason is OK.
    for s in 0..2u32 {
        for i in 0..2u32 {
            for c in 0..2u32 {
                assert_eq!(
                    receipt_accepted(s, i, c),
                    reject_reason(s, i, c) == OK,
                    "accept vs reason disagree at ({s},{i},{c})"
                );
            }
        }
    }
}

#[test]
fn a_signature_over_a_wrong_result_is_still_rejected() {
    // The reason recompute exists: a valid signature is WHO, not correctness.
    assert!(
        !receipt_accepted(1, 1, 0),
        "valid sig, wrong compute -> rejected"
    );
    assert_eq!(
        reject_reason(1, 1, 0),
        BAD_COMPUTE,
        "and the reason is bad compute, not bad sig"
    );
}

#[test]
fn correctness_uses_the_recompute_for_the_actual_op() {
    assert_eq!(compute_ok_for_op(GF_OP_MUL, 1, 0), 1, "MUL uses mul_ok");
    assert_eq!(compute_ok_for_op(GF_OP_ADD, 0, 1), 1, "ADD uses add_ok");
    assert_eq!(compute_ok_for_op(GF_OP_MUL, 0, 1), 0, "MUL ignores add_ok");
    assert_eq!(compute_ok_for_op(GF_OP_ADD, 1, 0), 0, "ADD ignores mul_ok");
    assert_eq!(
        compute_ok_for_op(0x99, 1, 1),
        0,
        "unknown op is never recomputable"
    );
}

#[test]
fn the_whitelist_blacklist_asymmetry_is_safe_only_on_boolean_inputs() {
    // receipt_accepted checks `== 1`, reject_reason checks `== 0`. On {0,1} they agree (proven
    // above). A non-boolean input (e.g. 2) would make them DISAGREE, so the wrapper must feed 0/1.
    assert!(
        !receipt_accepted(2, 1, 1),
        "a non-1 sig is rejected by the accept path"
    );
    assert_eq!(
        reject_reason(2, 1, 1),
        OK,
        "but reject_reason treats non-0 as pass -> OK"
    );
    // Hence: only 0/1 keeps the two paths consistent; this is a caller contract, pinned so a future
    // change that lets a check return >1 cannot silently accept via one path and reject via the other.
}
