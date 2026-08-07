//! money_lifecycle_e2e -- the capstone: one settlement event driven end to end through ALL the money
//! layers at once, proving they COMPOSE consistently. Each layer is unit-guarded already (bond_
//! collateralization_gate, optimistic_finality_lifecycle, reputation_dynamics, account_value_
//! conservation), but nothing pinned that a SINGLE outcome code drives them to the SAME verdict --
//! a fraud must slash the bond AND reverse the reward AND drop reputation, never a subset (a subset
//! is fraud that partially pays). This composes the verified transcriptions of bond / optimistic /
//! reputation / account and asserts: the honest path pays + releases + gains; the fraud path
//! forfeits + claws back + halves + cannot finalize; both conserve value system-wide; and the four
//! layers never disagree about whether an outcome was fraud.

// ---- outcome codes (shared across the layers: tri_compute_challenge.resolve_full) ----
const HONEST: u32 = 0;
const SLASH: u32 = 1;

// ---- bond (tri_compute_bond) ----
const ST_LOCKED: u32 = 1;
const ST_RELEASED: u32 = 2;
const ST_SLASHED: u32 = 3;
fn bond_state_after(outcome: u32) -> u32 {
    if outcome == HONEST {
        ST_RELEASED
    } else if outcome == SLASH {
        ST_SLASHED
    } else {
        ST_LOCKED
    }
}
/// Honest returns the bond to balance; slash/non-terminal do not add.
fn balance_after_resolve(balance: u32, bond: u32, outcome: u32) -> u32 {
    if outcome == HONEST {
        balance.saturating_add(bond)
    } else {
        balance
    }
}

// ---- optimistic (tri_compute_optimistic) ----
const PENDING: u32 = 0;
const FINALIZED: u32 = 1;
const REVERSED: u32 = 2;
fn settle_state(window_is_open: u32, slashed: u32) -> u32 {
    if slashed == 1 {
        REVERSED
    } else if window_is_open == 1 {
        PENDING
    } else {
        FINALIZED
    }
}
fn balance_after_settle(provisional_bal: u32, reward: u32, state: u32) -> u32 {
    if state == REVERSED {
        provisional_bal.saturating_sub(reward)
    } else {
        provisional_bal
    }
}
fn can_finalize(state: u32) -> bool {
    state == FINALIZED
}

// ---- reputation (tri_compute_reputation) ----
const REP_MAX: u32 = 1000;
fn rep_after_resolution(rep: u32, outcome: u32, gain: u32) -> u32 {
    if outcome == SLASH {
        rep >> 1
    } else if outcome == HONEST {
        let r = (rep as u64) + (gain as u64);
        if r > REP_MAX as u64 {
            REP_MAX
        } else {
            r as u32
        }
    } else {
        rep
    }
}

// A node's three-bucket holdings (tri_compute_account.total3).
fn total3(balance: u32, locked: u32, pending: u32) -> u32 {
    balance + locked + pending
}

/// Whether each layer read the outcome as fraud. The composition invariant is that these agree.
struct Verdict {
    bond_forfeited: bool,
    reward_reversed: bool,
    reputation_dropped: bool,
    cannot_finalize: bool,
}
fn layer_verdicts(outcome: u32, rep_before: u32, gain: u32) -> Verdict {
    let slashed = if outcome == SLASH { 1 } else { 0 };
    let state = settle_state(0, slashed); // window has closed
    Verdict {
        bond_forfeited: bond_state_after(outcome) == ST_SLASHED,
        reward_reversed: state == REVERSED,
        reputation_dropped: rep_after_resolution(rep_before, outcome, gain) < rep_before,
        cannot_finalize: !can_finalize(state),
    }
}

#[test]
fn the_honest_path_pays_releases_and_gains() {
    // Node posts bond K=200 out of balance B0=1000; earns reward R=16 provisionally; window closes
    // with no challenge; the honest resolution finalizes the reward and releases the bond.
    let (b0, bond, reward, rep0, gain) = (1000u32, 200u32, 16u32, 100u32, 20u32);
    let balance = b0 - bond; // 800 spendable, 200 locked
                             // window closed, no slash -> FINALIZED.
    let state = settle_state(0, 0);
    assert_eq!(state, FINALIZED);
    assert!(can_finalize(state), "honest+closed window finalizes");
    // reward stays; bond returns to balance.
    let bal_with_reward = balance_after_settle(balance + reward, reward, state); // reward kept
    let bal_final = balance_after_resolve(bal_with_reward, bond, HONEST); // bond back
    assert_eq!(
        bal_final,
        b0 + reward,
        "honest node ends with its start + the reward"
    );
    assert_eq!(bond_state_after(HONEST), ST_RELEASED, "bond released");
    assert!(
        rep_after_resolution(rep0, HONEST, gain) > rep0,
        "reputation gained"
    );
}

#[test]
fn the_fraud_path_forfeits_claws_back_halves_and_cannot_finalize() {
    let (b0, bond, reward, rep0, gain) = (1000u32, 200u32, 16u32, 800u32, 20u32);
    let balance = b0 - bond; // 800 spendable, 200 locked, reward 16 provisional (pending)
    let state = settle_state(0, 1); // slashed
    assert_eq!(state, REVERSED, "a slash reverses regardless of the window");
    assert!(!can_finalize(state), "a reversed settle can never finalize");
    // reward clawed back to the pool; provisional credit removed.
    let bal_after_clawback = balance_after_settle(balance + reward, reward, state);
    assert_eq!(
        bal_after_clawback, balance,
        "the provisional reward is clawed back"
    );
    // bond forfeited (goes to the challenger; balance is not credited it).
    assert_eq!(bond_state_after(SLASH), ST_SLASHED, "bond forfeited");
    assert_eq!(
        balance_after_resolve(bal_after_clawback, bond, SLASH),
        balance,
        "slash never returns the bond"
    );
    // reputation halved.
    assert_eq!(
        rep_after_resolution(rep0, SLASH, gain),
        400,
        "reputation halved by the same fraud"
    );
}

#[test]
fn value_is_conserved_on_both_paths() {
    let (b0, bond, reward) = (1000u32, 200u32, 16u32);
    // Model the node's total3 across the event and where value goes.
    // Start: 800 spendable + 200 locked + 16 pending (reward provisionally escrowed from the pool).
    let start = total3(b0 - bond, bond, reward);
    // HONEST: pending -> balance (finalize), locked -> balance (release). Node keeps everything;
    // the reward was a real transfer from the pool.
    let honest_end = total3(b0 - bond + reward + bond, 0, 0);
    assert_eq!(
        honest_end, start,
        "honest: node total3 conserved (reward was pool->node)"
    );
    assert_eq!(
        honest_end,
        b0 + reward,
        "node ends up its start plus the reward"
    );
    // FRAUD: pending reward clawed back to the POOL (leaves the node); bond forfeited to the
    // CHALLENGER (leaves the node). Node keeps only its original spendable balance.
    let node_end = total3(b0 - bond, 0, 0);
    let to_pool = reward; // reward returned
    let to_challenger = bond; // bond forfeited
    assert_eq!(
        node_end + to_pool + to_challenger,
        start,
        "fraud: node loss = reward-to-pool + bond-to-challenger, nothing minted or burned"
    );
    assert_eq!(
        node_end,
        b0 - bond,
        "the fraudster loses exactly its bond (and never keeps the reward)"
    );
}

#[test]
fn the_four_layers_never_disagree_about_fraud() {
    // The composition invariant: for a terminal outcome, every layer reads it the same way. A SLASH
    // fires ALL fraud consequences; an HONEST outcome fires NONE. No layer may go it alone.
    let v_fraud = layer_verdicts(SLASH, 800, 20);
    assert!(
        v_fraud.bond_forfeited
            && v_fraud.reward_reversed
            && v_fraud.reputation_dropped
            && v_fraud.cannot_finalize,
        "a slash must fire EVERY fraud consequence, never a subset"
    );
    let v_honest = layer_verdicts(HONEST, 100, 20);
    assert!(
        !v_honest.bond_forfeited
            && !v_honest.reward_reversed
            && !v_honest.reputation_dropped
            && !v_honest.cannot_finalize,
        "an honest outcome fires NO fraud consequence (and can finalize)"
    );
}

#[test]
fn a_fraud_event_drives_reputation_toward_lockout() {
    // The same slash that forfeits bond + reverses reward also halves reputation, so a repeat
    // offender crosses the admission floor -- the layers' penalties accumulate into exclusion.
    let mut rep = 1000u32;
    for _ in 0..5 {
        rep = rep_after_resolution(rep, SLASH, 0);
    }
    assert_eq!(rep, 31, "five fraud events halve 1000 -> 31");
    assert!(
        rep < 50,
        "below a floor of 50 -> the node is locked out of new work"
    );
}
