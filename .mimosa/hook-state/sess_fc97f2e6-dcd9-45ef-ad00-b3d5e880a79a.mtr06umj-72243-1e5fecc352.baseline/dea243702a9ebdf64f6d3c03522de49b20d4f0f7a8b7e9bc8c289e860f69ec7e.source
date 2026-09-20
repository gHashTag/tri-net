//! trinet_optimistic_settle -- the optimistic settlement lifecycle end-to-end.
//!
//! A bonded receipt is credited PROVISIONALLY, a challenge window opens; an
//! unchallenged receipt FINALIZES (credit kept, bond released), a challenged one --
//! where a challenger recomputes (tri_gft_arith) and resolve() slashes -- is REVERSED
//! (credit clawed back, bond slashed, challenger rewarded). Composes tri_compute_
//! optimistic + tri_compute_bond + tri_compute_challenge + the GF-T recompute.
#![allow(dead_code, unused)]

#[path = "../../gen/rust/tri_compute_optimistic.rs"] mod opt;
#[path = "../../gen/rust/tri_compute_bond.rs"] mod bond;
#[path = "../../gen/rust/tri_compute_challenge.rs"] mod ch;
#[path = "../../gen/rust/tri_gft_arith.rs"] mod gfa;

fn main() {
    let (reward, bond_amt) = (16u32, 100u32);
    let ex_bal0 = 1000u32;

    // Executor posts a bond and an optimistic settle credits the reward provisionally.
    assert!(bond::can_post(ex_bal0, bond_amt));
    let bal_prov = opt::provisional_balance(ex_bal0, reward, 1); // 1016
    let (settled_at, window) = (3u32, 10u32);

    // --- Case A: unchallenged. Time advances past the window -> FINALIZED, kept. ---
    let now_a = 13u32;
    let w_open_a = if opt::window_open(now_a, settled_at, window) { 1u32 } else { 0 };
    let state_a = opt::settle_state(w_open_a, 0);
    let bal_a = opt::balance_after_settle(bal_prov, reward, state_a);
    assert_eq!(state_a, opt::FINALIZED);
    assert!(opt::can_finalize(state_a));
    assert_eq!(bal_a, 1016, "unchallenged finalizes and keeps the reward");

    // --- Case B: challenged inside the window with a FRAUD claim -> REVERSED. ---
    let now_b = 5u32; // within [3,13)
    let honest = gfa::gft_mul_result(41, 0, 41, 0, gfa::GFT16_BIAS, gfa::GFT16_OFFSET_MAX); // encode(42,0)
    let claimed_fraud = gfa::gft_result_encode(43, 0); // executor lied
    let recomputed = gfa::gft_mul_result(41, 0, 41, 0, gfa::GFT16_BIAS, gfa::GFT16_OFFSET_MAX);
    let outcome = ch::resolve(claimed_fraud, recomputed);
    let slashed = if outcome == ch::RESOLVE_SLASH { 1u32 } else { 0 };
    let w_open_b = if opt::window_open(now_b, settled_at, window) { 1u32 } else { 0 };
    let state_b = opt::settle_state(w_open_b, slashed);
    let bal_b = opt::balance_after_settle(bal_prov, reward, state_b);
    let ex_bond_after = ch::executor_bond_after(bond_amt, outcome);
    let ch_reward = ch::challenger_reward(bond_amt, outcome);
    assert_eq!(state_b, opt::REVERSED);
    assert_eq!(bal_b, 1000, "reversed -> reward clawed back");
    assert_eq!((ex_bond_after, ch_reward), (0, bond_amt), "bond slashed, challenger paid");

    // --- Case C: challenged but the receipt is HONEST -> challenge fails, stays PENDING/kept. ---
    let outcome_c = ch::resolve(honest, recomputed);
    let slashed_c = if outcome_c == ch::RESOLVE_SLASH { 1u32 } else { 0 };
    let state_c = opt::settle_state(1, slashed_c); // in window
    assert_eq!(state_c, opt::PENDING);
    assert_eq!(opt::balance_after_settle(bal_prov, reward, state_c), 1016, "honest survives a false challenge");

    println!("optimistic settlement lifecycle:");
    println!("  provisional credit: 1000 + {} = {} (bond {} locked)", reward, bal_prov, bond_amt);
    println!("  A unchallenged, window closed -> FINALIZED, balance {}", bal_a);
    println!("  B fraud challenged in-window   -> REVERSED, balance {} (bond {}->{}, challenger +{})", bal_b, bond_amt, ex_bond_after, ch_reward);
    println!("  C honest, false challenge       -> PENDING, balance kept 1016");
    println!("OK: optimistic settle credits provisionally; only a successful recompute-backed challenge reverses + slashes");
}
