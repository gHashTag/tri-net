//! dispute_concurrency -- CI guard for the concurrent-dispute layer of the challenge game
//! (specs/tri_challenge.t27). One defender can face many challengers at once; without a slot cap
//! and a risk ledger, a swarm could grief a node with unbounded simultaneous disputes or open
//! disputes whose summed value-at-risk exceeds the defender's bond (a multi-loss the bond cannot
//! pay in full). This transcribes the new admission gate and pins: the exact slot cap, risk-ledger
//! conservation and saturation, admission monotonicity, the exact-coverage edge, and the mulDiv
//! parity with tri_compute_bond's collateral discipline (CH_BPS_UNIT literally equals
//! BOND_BPS_UNIT across the two specs -- they cannot drift apart silently).

const CH_SPEC: &str = include_str!("../specs/tri_challenge.t27");
const BOND_SPEC: &str = include_str!("../specs/tri_compute_bond.t27");

fn spec_const(src: &str, name: &str) -> u128 {
    for line in src.lines() {
        let t = line.trim();
        if t.starts_with("const") && t.contains(name) && t.contains('=') {
            let rhs = t.split('=').nth(1).expect("const has '='");
            let dec: String = rhs
                .chars()
                .skip_while(|c| !c.is_ascii_digit())
                .take_while(|c| c.is_ascii_digit())
                .collect();
            return dec.parse().expect("spec const decimal");
        }
    }
    panic!("const {name} not found in spec");
}

// ---- transcriptions ----
const MAX_OPEN_DISPUTES: u32 = 3;
const BPS_UNIT: u32 = 10000;

fn dispute_slots_ok(open_count: u32) -> bool {
    open_count < MAX_OPEN_DISPUTES
}
fn risk_after_open(risk: u32, reward: u32) -> u32 {
    risk.saturating_add(reward)
}
fn risk_after_close(risk: u32, reward: u32) -> u32 {
    risk.saturating_sub(reward)
}
fn dispute_required_bond(outstanding: u32, min_bps: u32) -> u32 {
    ((u64::from(outstanding) * u64::from(min_bps)) / u64::from(BPS_UNIT)) as u32
}
fn may_open_dispute(open_count: u32, risk: u32, reward: u32, bond: u32, min_bps: u32) -> bool {
    if !dispute_slots_ok(open_count) {
        return false;
    }
    bond >= dispute_required_bond(risk_after_open(risk, reward), min_bps)
}

#[test]
fn the_bps_unit_is_literally_the_bond_specs_unit() {
    // The dispute ledger mirrors tri_compute_bond's collateral discipline; if either spec
    // retunes its basis-point unit alone, this fails before behavior can drift.
    assert_eq!(
        spec_const(CH_SPEC, "CH_BPS_UNIT"),
        spec_const(BOND_SPEC, "BOND_BPS_UNIT"),
        "bps unit parity across tri_challenge and tri_compute_bond"
    );
    assert_eq!(u128::from(BPS_UNIT), spec_const(CH_SPEC, "CH_BPS_UNIT"));
    assert_eq!(
        u128::from(MAX_OPEN_DISPUTES),
        spec_const(CH_SPEC, "MAX_OPEN_DISPUTES")
    );
}

#[test]
fn the_slot_cap_is_exact() {
    for n in 0..MAX_OPEN_DISPUTES {
        assert!(
            dispute_slots_ok(n),
            "slot {n} of {MAX_OPEN_DISPUTES} may open"
        );
    }
    assert!(
        !dispute_slots_ok(MAX_OPEN_DISPUTES),
        "the cap itself admits nothing"
    );
    assert!(
        !dispute_slots_ok(MAX_OPEN_DISPUTES + 7),
        "and beyond stays closed"
    );
}

#[test]
fn the_risk_ledger_conserves_over_open_close_sequences() {
    // Any interleaving of opens and matching closes returns to the baseline.
    let rewards = [40u32, 100, 7, 500];
    let mut risk = 250u32;
    for r in rewards {
        risk = risk_after_open(risk, r);
    }
    assert_eq!(risk, 250 + 647, "opens accumulate");
    for r in rewards.iter().rev() {
        risk = risk_after_close(risk, *r);
    }
    assert_eq!(risk, 250, "closes return to the baseline in any order");
    assert_eq!(risk_after_close(30, 40), 0, "close floors at zero");
    assert_eq!(
        risk_after_open(u32::MAX - 8, 100),
        u32::MAX,
        "open saturates"
    );
}

#[test]
fn admission_is_monotone_in_bond_and_exact_at_full_coverage() {
    // risk 400 + reward 100 at 20% requires exactly 100.
    assert!(
        may_open_dispute(1, 400, 100, 100, 2000),
        "exact cover admits"
    );
    assert!(
        !may_open_dispute(1, 400, 100, 99, 2000),
        "one unit short is rejected"
    );
    for bond in [100u32, 101, 500, 10_000] {
        assert!(
            may_open_dispute(1, 400, 100, bond, 2000),
            "a bigger bond never turns admission off (bond {bond})"
        );
    }
    assert!(
        !may_open_dispute(MAX_OPEN_DISPUTES, 0, 1, u32::MAX, 1),
        "no slot, no dispute"
    );
}

#[test]
fn a_swarm_cannot_out_open_the_bond() {
    // Sequential admissions against one bond: each open moves the ledger, and the gate
    // stops exactly when the NEXT dispute's risk would exceed coverage.
    let (bond, min_bps, reward) = (100u32, 2000u32, 200u32);
    let mut risk = 0u32;
    let mut opened = 0u32;
    while may_open_dispute(opened, risk, reward, bond, min_bps) {
        risk = risk_after_open(risk, reward);
        opened += 1;
    }
    // bond 100 at 20% covers outstanding 500 => two 200-reward disputes (400) admit,
    // the third (600 -> requires 120) is rejected by COVERAGE before the slot cap bites.
    assert_eq!(opened, 2, "coverage stops the swarm before the slot cap");
    assert!(
        dispute_slots_ok(opened),
        "a slot was still free -- the bond was the binding limit"
    );
    assert_eq!(
        dispute_required_bond(risk_after_open(risk, reward), min_bps),
        120,
        "the rejected third dispute would need 120 > bond 100"
    );
}
