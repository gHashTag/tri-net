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
#[path = "../../gen/rust/tri_a2a.rs"]
mod a2a;
#[path = "../../gen/rust/tri_compute_bond.rs"]
mod bond;
#[path = "../../gen/rust/tri_compute_bitnet.rs"]
mod bitnet;
#[path = "../../gen/rust/tri_sha256.rs"]
mod sha;

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
    // INGRESS GATE: the node admits the result before ANY settlement -- it must bind
    // to the assignment (task + family + op), be fresh (beyond the watermark), and
    // come from an executor above the reputation floor. Settlement is gated on it,
    // so an unbound / stale / low-reputation result never reaches escrow.
    let task_id = 0x777u32;
    let watermark = 0x100u32;
    let (exec_rep, min_rep) = (100u32, 50u32);
    let admitted = a2a::admit_result(task_id, task_id, task_id, a2a::SKILL_GF16_MUL, receipt::FMT_GF_BINARY, op, watermark, exec_rep, min_rep);
    assert!(admitted, "a bound, fresh, reputable result is admitted at ingress");
    // Settle mints the reward into ESCROW through the GATED path (only if admitted):
    // settle_canonical applies sig -> no-double-pay -> freshness -> payability, so
    // only a valid, fresh, finite, once-only receipt escrows value.
    let pending = if admitted {
        settle::settle_canonical(0, width, 1, 1, 0, settle::FMT_GF_BINARY, r_ok, 6, 9, 1, 0)
    } else {
        0
    }; // 16
    assert_eq!(pending, reward, "a valid finite receipt escrows exactly the width reward");
    assert_eq!(account::bal_after_clawback(bal), bal, "settled reward is not spendable yet");
    // The gate now bites in escrow: a non-finite result or an unsigned receipt
    // escrows ZERO (the bypass the old compute_reward path allowed).
    assert_eq!(settle::settle_canonical(0, width, 1, 1, 0, settle::FMT_GF_BINARY, 0x7E00, 6, 9, 1, 0), 0, "inf result escrows nothing");
    assert_eq!(settle::settle_canonical(0, width, 0, 1, 0, settle::FMT_GF_BINARY, r_ok, 6, 9, 1, 0), 0, "unsigned receipt escrows nothing");
    // A result rejected AT INGRESS never reaches settlement at all. Each failure
    // mode is independently disqualifying, and a rejected result escrows nothing.
    let bad_op = a2a::admit_result(task_id, task_id, task_id, a2a::SKILL_GF16_MUL, receipt::FMT_GF_BINARY, 0x10, watermark, exec_rep, min_rep);
    assert!(!bad_op, "an add receipt for a mul assignment is rejected at ingress");
    let bad_pending = if bad_op {
        settle::settle_canonical(0, width, 1, 1, 0, settle::FMT_GF_BINARY, r_ok, 6, 9, 1, 0)
    } else {
        0
    };
    assert_eq!(bad_pending, 0, "an ingress-rejected result is never settled");
    assert!(!a2a::admit_result(task_id, watermark, watermark, a2a::SKILL_GF16_MUL, receipt::FMT_GF_BINARY, op, watermark, exec_rep, min_rep), "a stale (id == watermark) result is rejected at ingress");
    assert!(!a2a::admit_result(task_id, task_id, task_id, a2a::SKILL_GF16_MUL, receipt::FMT_GF_BINARY, op, watermark, 40, min_rep), "a sub-floor-reputation executor is rejected at ingress");
    // Challenger recomputes the leaf from the committed operands + golden result;
    // it reproduces the settled leaf, so the dispute is anchored.
    let dispute_leaf = receipt::receipt_leaf_gf_fmt(receipt::FMT_GF_BINARY, width, op, a, b, r_ok, dev, exe, epoch);
    // Dispute at epoch 3 (inside the window): recompute == claim -> HONEST.
    let out_h = challenge::resolve_full(0, 3, challenge::FMT_GF_BINARY, challenge::FMT_GF_BINARY, leaf_ok, dispute_leaf, r_ok, r_ok);
    assert_eq!(out_h, challenge::RESOLVE_HONEST, "correct result on committed operands -> honest");
    // The SAME dispute on the 256-bit receipt digest (not the 32-bit leaf): run the
    // real tri_sha256 over digest_pre for a 2^128 anchor, then resolve_full_d256. A
    // fabricated dispute (different committed result) yields a different digest ->
    // leaf_match = 0 -> MALFORMED, closing the ~2^16 leaf collision for GF disputes.
    let gf_digest = |out_val: u32| -> [u32; 8] {
        let w = |i: u32| receipt::digest_pre(i, 0x2001, dev, exe, op, a, out_val, epoch, receipt::RECEIPT_GENESIS);
        let mut d = [0u32; 8];
        let mut j = 0u32;
        while j < 8 {
            d[j as usize] = sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), j);
            j += 1;
        }
        d
    };
    let settled_gf = gf_digest(r_ok);
    let gf_match = if gf_digest(r_ok) == settled_gf { 1u32 } else { 0u32 };
    assert_eq!(challenge::resolve_full_d256(0, 3, challenge::FMT_GF_BINARY, challenge::FMT_GF_BINARY, gf_match, r_ok, r_ok), challenge::RESOLVE_HONEST, "256-bit-anchored GF dispute -> honest");
    let gf_fab = if gf_digest(r_bad) == settled_gf { 1u32 } else { 0u32 };
    assert_eq!(gf_fab, 0, "a different committed result yields a different 256-bit receipt digest (no collision)");
    assert_eq!(challenge::resolve_full_d256(0, 3, challenge::FMT_GF_BINARY, challenge::FMT_GF_BINARY, gf_fab, r_bad, r_ok), challenge::RESOLVE_MALFORMED, "fabricated GF dispute -> malformed on the 256-bit anchor");
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

    // ---- Same dispute under a 5-node quorum (3 honest, 2 colluding) ----
    // The 3-of-5 majority recomputes the golden r_ok and still slashes the executor
    // despite TWO liars; the two colluders' stake (100) splits among the 3 honest
    // (33 each, net 83), and no over-issuance -- the 5-node economics on real Rust.
    let (w0, w1, w2, w3, w4) = (r_ok, r_ok, r_ok, r_bad, r_bad); // 3 honest, 2 colluding
    let out_f5 = challenge::resolve_quorum5(0, 5, challenge::FMT_GF_BINARY, challenge::FMT_GF_BINARY, leaf_bad, dispute_leaf_bad, r_bad, w0, w1, w2, w3, w4);
    assert_eq!(out_f5, challenge::RESOLVE_SLASH, "3-of-5 majority slashes the fraud despite two colluders");
    let honest5 = challenge::max_agree5(w0, w1, w2, w3, w4);
    let dissenters5 = challenge::dissenter_count5(w0, w1, w2, w3, w4);
    assert_eq!(honest5, 3, "3 honest form the quorum");
    assert_eq!(dissenters5, 2, "2 colluders dissent");
    let burned5 = challenge::burned_total5(w0, w1, w2, w3, w4, 50);
    let share5 = challenge::honest_share5(w0, w1, w2, w3, w4, 50);
    assert_eq!(burned5, 100, "two 50-stakes burned");
    assert_eq!(share5, 33, "100 split among 3 honest -> 33 each");
    assert_eq!(challenge::verifier_stake_after(50, 0) + share5, 83, "5-node honest net = 50 + 33 = 83");
    assert!(honest5 * share5 <= burned5, "no over-issuance on the 5-node split");

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
    println!("  ingress: result admitted (bound+fresh+reputable); wrong-op/stale/low-rep rejected before settle");
    println!("  honest: settle {} into escrow, window elapses, finalize + release -> total {}", reward, honest_total);
    println!("  fraud:  settle {} into escrow, in-window SLASH -> clawback + bond slash -> total {}", reward, fraud_total);
    println!("  invariant: cheating costs reward+bond = {} (honest {} - fraud {})", reward + bond, honest_total, fraud_total);
    println!("  quorum: 3 verifiers (1 colluding) -> majority slashes; executor rep 1000->{}", exe_rep_after);
    println!("  verifiers: colluder stake burned + rep->500; honest keep stake + rep->120 + share {} = net {}", each, honest_net);
    println!("  5-node quorum: 3 honest / 2 colluders -> slash; 2 burned stakes -> honest share {} net 83", share5);
    println!("  real recompute: 3 verifiers recompute the leaf; honest quorum 0x{:X}, tamperer flagged", qv_leaf);
    // ---- Multi-task collateralization: the bond gate reads a maintained counter ----
    // A node with bond 100 at 100% coverage can carry at most 100 of outstanding
    // escrow. It admits a new task only if the bond covers the outstanding INCLUDING
    // that task; a task leaving escrow (finalize/clawback) frees room again. This is
    // the outstanding counter (account) feeding the collateralization gate (bond).
    let node_bond = 100u32;
    let cover_bps = 10000u32; // 100%
    let mut outstanding_now = 0u32;
    // Task A (escrow 60): prospective 60 <= 100 -> admitted.
    let prospective_a = account::outstanding_after_escrow(outstanding_now, 60);
    assert!(bond::bond_covers(node_bond, prospective_a, cover_bps), "bond covers the first task");
    outstanding_now = prospective_a; // 60 now at risk
    // Task B (escrow 60): prospective 120 > 100 -> REJECTED, outstanding stays 60.
    let prospective_b = account::outstanding_after_escrow(outstanding_now, 60);
    assert!(!bond::bond_covers(node_bond, prospective_b, cover_bps), "an under-collateralized second task is rejected");
    assert_eq!(outstanding_now, 60, "the rejected task did not raise the at-risk counter");
    // Task A finalizes -> outstanding drops to 0, freeing collateral room.
    outstanding_now = account::outstanding_after_release(outstanding_now, 60);
    assert_eq!(outstanding_now, 0, "finalizing task A releases its at-risk escrow");
    // Task B retried now: prospective 60 <= 100 -> admitted.
    let prospective_b2 = account::outstanding_after_escrow(outstanding_now, 60);
    assert!(bond::bond_covers(node_bond, prospective_b2, cover_bps), "with room freed, task B is now admitted");

    println!("  guards: replay -> STALE, cross-family -> FAMILY_MISMATCH, premature finalize -> no-op");
    // ---- BitNet-layer dispute: ternary recompute + GF value, under a quorum ----
    // A BitNet layer commits canonical ternary weights (weight_code) whose sign
    // balance a verifier recomputes (bitnet_balance_matches -> ternary_ok), plus a
    // GF accumulate. resolve_bitnet_quorum takes the 3-of-3 majority of the value
    // AND the ternary flag, so both parts are verified and a lone liar is outvoted.
    let weight_code = 0x61u32; // canonical: pos 2, neg 1
    let claimed_balance = bitnet::sign_balance_biased(weight_code); // 5
    // Honest verifiers recompute the ternary part and agree it is valid.
    let tern_ok = if bitnet::bitnet_balance_matches(weight_code, claimed_balance) { 1u32 } else { 0u32 };
    assert_eq!(tern_ok, 1, "canonical weights + correct balance -> ternary verified");
    // Honest BitNet layer: leaf bound, value majority r_ok, ternary majority OK -> honest.
    let bn_leaf = receipt::receipt_leaf_gf_fmt(receipt::FMT_GF_BINARY, width, op, a, b, r_ok, dev, exe, epoch);
    let bn_honest = challenge::resolve_bitnet_quorum(bn_leaf, bn_leaf, r_ok, r_ok, r_ok, r_bad, tern_ok, tern_ok, 0);
    assert_eq!(bn_honest, challenge::RESOLVE_HONEST, "honest BitNet layer survives a value liar + a ternary liar");
    // Ternary fraud: executor claims a WRONG sign balance -> ternary_ok=0 majority -> slash.
    let tern_bad = if bitnet::bitnet_balance_matches(weight_code, 8) { 1u32 } else { 0u32 };
    assert_eq!(tern_bad, 0, "a wrong claimed balance fails the ternary recompute");
    let bn_fraud = challenge::resolve_bitnet_quorum(bn_leaf, bn_leaf, r_ok, r_ok, r_ok, r_ok, tern_bad, tern_bad, 1);
    assert_eq!(bn_fraud, challenge::RESOLVE_SLASH, "a 2-of-3 ternary-bad majority slashes the BitNet layer");

    // ---- The BitNet attestation on the 256-bit digest (not the 32-bit leaf) ----
    // Run the REAL SHA-256 over the BitNet preimage (bitnet_digest_pre) for a
    // 2^128-collision commitment, then resolve the dispute on it (resolve_bitnet_
    // d256). A dispute whose committed weight_code differs produces a different
    // 256-bit digest -> leaf_match = 0 -> MALFORMED, closing the ~2^16 birthday
    // collision the 32-bit leaf allowed.
    let bn_digest = |wc: u32| -> [u32; 8] {
        let w = |i: u32| bitnet::bitnet_digest_pre(i, wc, 0xABCD, r_ok, dev, exe, epoch);
        let mut d = [0u32; 8];
        let mut j = 0u32;
        while j < 8 {
            d[j as usize] = sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), j);
            j += 1;
        }
        d
    };
    let settled_d = bn_digest(weight_code);
    // Honest dispute: same committed weights -> digests match -> resolve on the strong anchor.
    let leaf_match = if bn_digest(weight_code) == settled_d { 1u32 } else { 0u32 };
    assert_eq!(leaf_match, 1, "the honest dispute reproduces the 256-bit digest");
    assert_eq!(challenge::resolve_bitnet_d256(leaf_match, r_ok, r_ok, tern_ok), challenge::RESOLVE_HONEST, "256-bit-anchored honest layer");
    // A fabricated dispute (different weight_code) -> different digest -> no match -> malformed.
    let fabricated_match = if bn_digest(0x62) == settled_d { 1u32 } else { 0u32 };
    assert_eq!(fabricated_match, 0, "a different weight_code yields a different 256-bit digest (no collision)");
    assert_eq!(challenge::resolve_bitnet_d256(fabricated_match, r_ok, r_ok, tern_ok), challenge::RESOLVE_MALFORMED, "fabricated dispute -> malformed on the 256-bit anchor");

    println!("  collateral: bond 100 carries task A(60); task B(->120) rejected; after A finalizes, B admitted");
    println!("  bitnet: canonical weights balance {} verified; ternary majority slashes a wrong-balance claim", claimed_balance);
    println!("  gf-256: receipt SHA-256 digest 0x{:08X}..; honest GF dispute matches, fabricated result -> malformed (no 2^16 collision)", settled_gf[0]);
    println!("  bitnet-256: SHA-256 digest 0x{:08X}..; honest dispute matches, fabricated weight_code -> malformed (no 2^16 collision)", settled_d[0]);
    println!("OK: the compute-receipt / escrow / challenge / quorum / reputation / collateral / bitnet specs compose end-to-end on real Rust");
}
