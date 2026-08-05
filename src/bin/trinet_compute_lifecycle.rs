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
#[path = "../../gen/rust/tri_compute_reputation.rs"]
mod reputation;

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
    // Settle mints the reward into ESCROW through the GATED path: settle_canonical
    // fed an empty pending bucket applies sig -> no-double-pay -> freshness ->
    // payability, so only a valid, fresh, finite, once-only receipt escrows value.
    // (An earlier version escrowed compute_reward(width, 1) directly, bypassing
    // every gate but freshness -- a non-finite or unsigned result would still have
    // escrowed the full reward. The gated path closes that hole.)
    let pending = settle::settle_canonical(0, width, 1, 1, 0, settle::FMT_GF_BINARY, r_ok, 6, 9, 1, 0); // 16
    assert_eq!(pending, reward, "a valid finite receipt escrows exactly the width reward");
    assert_eq!(account::bal_after_clawback(bal), bal, "settled reward is not spendable yet");
    // The gate now bites in escrow: a non-finite result or an unsigned receipt
    // escrows ZERO (the bypass the old compute_reward path allowed).
    assert_eq!(settle::settle_canonical(0, width, 1, 1, 0, settle::FMT_GF_BINARY, 0x7E00, 6, 9, 1, 0), 0, "inf result escrows nothing");
    assert_eq!(settle::settle_canonical(0, width, 0, 1, 0, settle::FMT_GF_BINARY, r_ok, 6, 9, 1, 0), 0, "unsigned receipt escrows nothing");
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
    let pending_f = settle::settle_canonical(0, width, 1, 1, 0, settle::FMT_GF_BINARY, r_bad, 6, 9, 1, 0); // 16 escrowed (r_bad is finite; the fraud is caught by challenge, not payability)
    // Challenger recomputes the leaf from the SAME committed operands (r_bad), so it
    // reproduces the settled leaf, then supplies the golden r_ok as the recompute.
    let dispute_leaf_bad = receipt::receipt_leaf_gf_fmt(receipt::FMT_GF_BINARY, width, op, a, b, r_bad, dev, exe, epoch);
    // Dispute at epoch 5 (inside the window), resolved by a QUORUM of 3 verifiers
    // who each recompute gf_op: two honest return the golden r_ok, one colludes and
    // returns r_bad to shield the fraudster. Majority = r_ok, so the executor's
    // claim r_bad is still slashed -- a single lying verifier cannot save the fraud.
    let (ver0, ver1, ver2) = (r_ok, r_ok, r_bad); // two honest, one colluding
    let out_f = challenge::resolve_quorum3(0, 5, challenge::FMT_GF_BINARY, challenge::FMT_GF_BINARY, leaf_bad, dispute_leaf_bad, r_bad, ver0, ver1, ver2);
    assert_eq!(out_f, challenge::RESOLVE_SLASH, "majority recomputation slashes the fraud despite a colluding verifier");
    // In-window slash: clawback the escrowed reward (never spendable) + slash the bond.
    let bal_claw = account::bal_after_clawback(bal); // 800, reward reverted to pool
    let bond_after = challenge::executor_bond_after(bond, out_f); // 0 (slashed)
    let fraud_total = account::total3(bal_claw, bond_after, 0);
    assert_eq!(fraud_total, 800, "fraud: escrowed reward clawed + bond slashed");
    let cwin = challenge::challenger_reward(bond, out_f);
    assert_eq!(cwin, bond, "challenger wins the slashed bond");

    // ---- TWO-SIDED ACCOUNTABILITY: the one proof judges executor AND verifiers ----
    // Executor: the proven slash halves its reputation (memory the bond alone lacks).
    let exe_rep_after = reputation::rep_after_resolution(1000, out_f, 20);
    assert_eq!(exe_rep_after, 500, "proven fraud halves the executor's reputation");
    // Verifiers: quorum value is r_ok; the colluding verifier (ver2) dissented ->
    // stake burned + reputation halved; the two honest ones keep stake + gain rep.
    let hq = challenge::verifier_quorum3(ver0, ver1, ver2);
    let qv = challenge::quorum_result3(ver0, ver1, ver2);
    assert_eq!(hq, 1);
    assert_eq!(qv, r_ok);
    let d_honest = challenge::verifier_dissented(ver0, qv, hq);
    let d_collude = challenge::verifier_dissented(ver2, qv, hq);
    assert_eq!(challenge::verifier_stake_after(50, d_honest), 50, "honest verifier keeps its stake");
    assert_eq!(challenge::verifier_stake_after(50, d_collude), 0, "colluding verifier's stake is burned");
    assert_eq!(reputation::rep_after_verifier(1000, hq, d_collude, 20), 500, "colluding verifier reputation halved");
    assert_eq!(reputation::rep_after_verifier(100, hq, d_honest, 20), 120, "honest verifier reputation gains");
    // The colluder's burned 50 is split among the 2 honest verifiers -> 25 each,
    // so honest verification is NET-POSITIVE (kept 50 + 25 = 75 > 50 staked) and
    // self-funding -- the verifier's dilemma is closed on real Rust, not just the
    // spec harness.
    let burned = 50 - challenge::verifier_stake_after(50, d_collude); // staked 50 minus retained 0 = 50 burned
    let honest_count = 2u32;
    let each = challenge::verifier_reward(burned, honest_count);
    assert_eq!(each, 25, "burned 50 split between 2 honest -> 25 each");
    let honest_net = challenge::verifier_stake_after(50, d_honest) + each;
    assert_eq!(honest_net, 75, "honest verifier net = kept 50 + reward 25 = 75 > 50 staked");
    assert!(honest_count * each <= burned, "no over-issuance: 2*25 <= 50");

    // ---- The quorum runs over a REAL recompute, not literals ----
    // Each verifier independently recomputes the dispute leaf via a deterministic
    // on-branch function (receipt_leaf_gf_fmt) from the committed operands: two
    // honest ones get the same leaf, a tampering one (wrong committed result) gets
    // a different leaf, and the quorum confirms the honest majority + flags the
    // tamperer. (The gf-VALUE recompute -- gf_op(a,b) itself -- is the parallel
    // #110 GF-T arithmetic, wired in at merge per docs/RECONCILIATION_ring_hardening;
    // NOT duplicated here.)
    let leaf_v0 = receipt::receipt_leaf_gf_fmt(receipt::FMT_GF_BINARY, width, op, a, b, r_bad, dev, exe, epoch);
    let leaf_v1 = receipt::receipt_leaf_gf_fmt(receipt::FMT_GF_BINARY, width, op, a, b, r_bad, dev, exe, epoch);
    let leaf_v2 = receipt::receipt_leaf_gf_fmt(receipt::FMT_GF_BINARY, width, op, a, b, 0xDEAD, dev, exe, epoch);
    let hq_leaf = challenge::verifier_quorum3(leaf_v0, leaf_v1, leaf_v2);
    let qv_leaf = challenge::quorum_result3(leaf_v0, leaf_v1, leaf_v2);
    assert_eq!(hq_leaf, 1, "two honest leaf-recomputes form a quorum");
    assert_eq!(qv_leaf, leaf_v0, "the honest recomputed leaf is the quorum value");
    assert_eq!(challenge::verifier_dissented(leaf_v2, qv_leaf, hq_leaf), 1, "the tampering verifier dissents from the recomputed leaf");
    assert_ne!(leaf_v0, leaf_v2, "the deterministic recompute actually differs on a tampered operand");

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
    println!("  quorum: 3 verifiers (1 colluding) -> majority slashes; executor rep 1000->{}", exe_rep_after);
    println!("  verifiers: colluder stake burned + rep->500; honest keep stake + rep->120 + share {} = net {}", each, honest_net);
    println!("  real recompute: 3 verifiers recompute the leaf; honest quorum 0x{:X}, tamperer flagged", qv_leaf);
    println!("  guards: replay -> STALE, cross-family -> FAMILY_MISMATCH, premature finalize -> no-op");
    println!("OK: the compute-receipt / escrow / challenge / quorum / reputation specs compose end-to-end on real Rust");
}
