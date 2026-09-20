//! trinet_compute_verify -- the capstone CORRECTNESS check, dispatched by op.
//!
//! A compute receipt names its GoldenFloat op (MUL / ADD). The verifier must
//! recompute the ACTUAL op: a MUL receipt is checked with the multiply recompute
//! (tri_gft_arith), an ADD receipt with the add recompute -- same-sign magnitude
//! add (tri_gft_add) or, for different signs, the subtractive recompute
//! (tri_gft_sub). tri_receipt_verify.compute_ok_for_op selects the authoritative
//! result, which feeds the full receipt_accepted verdict. All arithmetic is
//! generated from specs; this binary is the (cross-module) dispatch wiring.
#![allow(dead_code, unused)]

#[path = "../../gen/rust/tri_gft_arith.rs"]
mod mul;
#[path = "../../gen/rust/tri_gft_add.rs"]
mod add;
#[path = "../../gen/rust/tri_gft_sub.rs"]
mod sub;
#[path = "../../gen/rust/tri_receipt_verify.rs"]
mod v;

/// ADD dispatches by sign: same sign adds magnitudes, different sign subtracts.
fn add_ok(sign_a: u32, sign_b: u32, oa: u32, ma: u32, ob: u32, mb: u32, coff: u32, cman: u32) -> u32 {
    let ok = if sign_a == sign_b {
        add::verify_gft_add(oa, ob, ma, mb, coff, cman, mul::GFT16_OFFSET_MAX)
    } else {
        sub::verify_gft_sub(oa, ob, ma, mb, coff, cman)
    };
    if ok { 1 } else { 0 }
}

fn mul_ok(oa: u32, ma: u32, ob: u32, mb: u32, coff: u32, cman: u32) -> u32 {
    if mul::verify_gft_mul_full(oa, ma, ob, mb, coff, cman, mul::GFT16_BIAS, mul::GFT16_OFFSET_MAX) { 1 } else { 0 }
}

fn main() {
    // Three honest GF-T16 receipts, one per arithmetic path.
    // MUL: phi^1 * phi^1 = phi^2  (offsets 41,41 -> 42, mantissa 0)
    let m = mul_ok(41, 0, 41, 0, 42, 0);
    // ADD same-sign: 1.0 + 1.0 = 2.0  (offset 40,40 -> 41, mantissa 0)
    let a_same = add_ok(0, 0, 40, 0, 40, 0, 41, 0);
    // ADD different-sign (subtract): 1.5 + (-1.0) = 0.5  (offset 40,40 -> 39, mantissa 0)
    let a_diff = add_ok(0, 1, 40, 256, 40, 0, 39, 0);

    let mul_verdict = v::compute_ok_for_op(v::GF_OP_MUL, m, 0);
    let add_same_verdict = v::compute_ok_for_op(v::GF_OP_ADD, 0, a_same);
    let add_diff_verdict = v::compute_ok_for_op(v::GF_OP_ADD, 0, a_diff);
    assert_eq!((mul_verdict, add_same_verdict, add_diff_verdict), (1, 1, 1), "all three honest ops verify");

    // Fraud: a MUL receipt claiming the wrong product exponent, and an ADD receipt
    // claiming a wrong sum -- each rejected by its own recompute.
    let m_bad = mul_ok(41, 0, 41, 0, 43, 0);
    let a_bad = add_ok(0, 0, 40, 0, 40, 0, 40, 0); // 1.0+1.0 is 2.0 (off 41), claiming off 40
    assert_eq!(v::compute_ok_for_op(v::GF_OP_MUL, m_bad, 0), 0, "wrong product exponent rejected");
    assert_eq!(v::compute_ok_for_op(v::GF_OP_ADD, 0, a_bad), 0, "wrong sum rejected");

    // The full capstone verdict for the honest MUL receipt (signed + batched here).
    let accepted = v::receipt_accepted(1, 1, mul_verdict);

    println!("compute-correctness dispatched by op (MUL / ADD):");
    println!("  MUL phi^1*phi^1=phi^2         -> compute_ok={}", mul_verdict);
    println!("  ADD 1.0+1.0=2.0 (same sign)   -> compute_ok={} (via tri_gft_add)", add_same_verdict);
    println!("  ADD 1.5+(-1.0)=0.5 (diff sign)-> compute_ok={} (via tri_gft_sub)", add_diff_verdict);
    println!("  MUL claims phi^2=off43        -> compute_ok={} (rejected)", v::compute_ok_for_op(v::GF_OP_MUL, m_bad, 0));
    println!("  full receipt_accepted(sig,batch,compute) for the honest MUL = {}", accepted);
    println!("OK: each op is verified by its OWN recompute; a receipt is correct only if its actual op recomputes");
}
