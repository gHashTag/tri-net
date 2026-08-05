//! trinet_compute_lifecycle -- the full compute-market lifecycle end-to-end over
//! the landed specs, proving they COMPOSE on real Rust: an executor posts a bond,
//! computes a GF op, settles the reward INTO ESCROW (not spendable), and then the
//! challenge window decides finality:
//!   honest -> window elapses, no fraud   -> finalize (reward spendable) + bond back
//!   fraud  -> bound fraud proof in-window -> SLASH -> clawback (reward reverted to
//!             the pool, never spent) + bond slashed to the challenger
//! It also exercises the guards landed this ring: replaying a resolved dispute is a
//! STALE no-op, a cross-family dispute is a FAMILY_MISMATCH, and a premature
//! finalize inside the window is a no-op. The GF recomputation is bit-exact and
//! proven on silicon elsewhere; here (as trinet_settle_signed treats the output)
//! the golden result is an oracle input and the ECONOMIC wiring is the subject.
#![allow(dead_code, unused)]

#[path = "../../gen/rust/tri_compute_receipt.rs"]
mod receipt;
#[path = "../../gen/rust/tri_compute_challenge.rs"]
mod challenge;
#[path = "../../gen/rust/tri_compute_settle.rs"]
mod settle;
#[path = "../../gen/rust/tri_compute_account.rs"]
mod account;

fn main() {
    // Shared task: a GF16 MUL over committed operands. r_ok is the golden result,
    // r_bad a wrong one a dishonest executor might commit.
    let (dev, exe, epoch) = (0xC0FFEE01u32, 0xE0E0u32, 1u32);
    let (op, a, b) = (receipt::GF_MUL, 0x3C00u32, 0x4000u32);
    let (r_ok, r_bad) = (0x4000u32, 0x9999u32);
    let width = receipt::GF16; // 16
    let window = 10u32; // challenge window, in epochs
    let reward = settle::compute_reward(width, 1); // 16 $TRI for a fresh width-16 op

    // Node starts at balance 1000; posts a 200 bond (lock: balance -> locked).
    let start = 1000u32;
    let bond = 200u32;
    let bal = account::bal_after_lock(start, bond); // 800
    let locked = account::locked_after_lock(start, 0, bond); // 200
    assert_eq!(account::total3(bal, locked, 0), start, "post-bond conserves total");

    // ---- HONEST PATH ----
    // Executor commits the correct result; the leaf binds (op,a,b,r_ok,...).
    let leaf_ok = receipt::receipt_leaf_gf_fmt(receipt::FMT_GF_BINARY, width, op, a, b, r_ok, dev, exe, epoch);
    // Settle mints the reward into ESCROW (pending), not spendable balance.
    let pending = account::pending_after_settle(0, reward); // 16
    assert_eq!(account::bal_after_clawback(bal), bal, "settled reward is not spendable yet");
    // Challenger recomputes the leaf from the committed operands + golden result;
    // it reproduces the settled leaf, so the dispute is anchored.
    let dispute_leaf = receipt::receipt_leaf_gf_fmt(receipt::FMT_GF_BINARY, width, op, a, b, r_ok, dev, exe, epoch);
    // Dispute at epoch 3 (inside the window): recompute == claim -> HONEST.
    let out_h = challenge::resolve_full(0, 3, challenge::FMT_GF_BINARY, challenge::FMT_GF_BINARY, leaf_ok, dispute_leaf, r_ok, r_ok);
    assert_eq!(out_h, challenge::RESOLVE_HONEST, "correct result on committed operands -> honest");
    // Window elapses (now >= settle_epoch + window) with no slash -> finalize, then
    // release the bond.
    let settle_epoch = 1u32;
    let now = settle_epoch + window; // 11
    let bal_final = account::bal_after_finalize_gated(bal, pending, settle_epoch, now, window); // 816
    let bal_released = account::bal_after_release(bal_final, locked); // 1016
    let honest_total = account::total3(bal_released, 0, 0);
    assert_eq!(honest_total, 1016, "honest: balance + reward + returned bond");

    // ---- FRAUD PATH ----
    // Executor commits a WRONG result; the leaf binds (op,a,b,r_bad,...).
    let leaf_bad = receipt::receipt_leaf_gf_fmt(receipt::FMT_GF_BINARY, width, op, a, b, r_bad, dev, exe, epoch);
    let pending_f = account::pending_after_settle(0, reward); // 16 escrowed
    // Challenger recomputes the leaf from the SAME committed operands (r_bad), so it
    // reproduces the settled leaf, then supplies the golden r_ok as the recompute.
    let dispute_leaf_bad = receipt::receipt_leaf_gf_fmt(receipt::FMT_GF_BINARY, width, op, a, b, r_bad, dev, exe, epoch);
    // Dispute at epoch 5 (inside the window): leaf binds, claim(r_bad) != recompute(r_ok) -> SLASH.
    let out_f = challenge::resolve_full(0, 5, challenge::FMT_GF_BINARY, challenge::FMT_GF_BINARY, leaf_bad, dispute_leaf_bad, r_bad, r_ok);
    assert_eq!(out_f, challenge::RESOLVE_SLASH, "wrong result on committed operands -> slash");
    // In-window slash: clawback the escrowed reward (never spendable) + slash the bond.
    let bal_claw = account::bal_after_clawback(bal); // 800, reward reverted to pool
    let bond_after = challenge::executor_bond_after(bond, out_f); // 0 (slashed)
    let fraud_total = account::total3(bal_claw, bond_after, 0);
    assert_eq!(fraud_total, 800, "fraud: escrowed reward clawed + bond slashed");
    let cwin = challenge::challenger_reward(bond, out_f);
    assert_eq!(cwin, bond, "challenger wins the slashed bond");

    // ---- THE ECONOMIC-SECURITY INVARIANT ----
    assert_eq!(honest_total - fraud_total, reward + bond, "cheating costs exactly reward + bond");

    // ---- GUARDS ----
    // Replay the resolved fraud dispute at the same watermark -> STALE no-op.
    let out_replay = challenge::resolve_full(5, 5, challenge::FMT_GF_BINARY, challenge::FMT_GF_BINARY, leaf_bad, dispute_leaf_bad, r_bad, r_ok);
    assert_eq!(out_replay, challenge::RESOLVE_STALE, "replay -> stale no-op");
    // Family confusion: dispute a binary-committed result as GF-T -> FAMILY_MISMATCH.
    let out_fam = challenge::resolve_full(0, 6, challenge::FMT_GF_BINARY, challenge::FMT_GFT, leaf_bad, dispute_leaf_bad, r_bad, r_ok);
    assert_eq!(out_fam, challenge::RESOLVE_FAMILY_MISMATCH, "cross-family -> mismatch");
    // Premature finalize (inside the window) is a no-op: reward stays escrowed.
    assert_eq!(account::bal_after_finalize_gated(bal, pending_f, settle_epoch, settle_epoch + 3, window), bal, "premature finalize keeps reward escrowed");

    println!("compute lifecycle end-to-end (receipt -> settle/escrow -> challenge window):");
    println!("  honest: settle {} into escrow, window elapses, finalize + release -> total {}", reward, honest_total);
    println!("  fraud:  settle {} into escrow, in-window SLASH -> clawback + bond slash -> total {}", reward, fraud_total);
    println!("  invariant: cheating costs reward+bond = {} (honest {} - fraud {})", reward + bond, honest_total, fraud_total);
    println!("  guards: replay -> STALE, cross-family -> FAMILY_MISMATCH, premature finalize -> no-op");
    println!("OK: the compute-receipt / escrow / challenge specs compose end-to-end on real Rust");
}
