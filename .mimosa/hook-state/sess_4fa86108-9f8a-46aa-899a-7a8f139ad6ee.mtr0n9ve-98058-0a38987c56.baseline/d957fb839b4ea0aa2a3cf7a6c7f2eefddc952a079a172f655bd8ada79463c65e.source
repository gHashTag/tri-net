//! dispute_witness -- CI guard for the witness quorum (specs/tri_challenge.t27). resolve()
//! compares the defender's seal to "the" recomputed truth, but a SINGLE recomputer is a trust
//! point: one malicious witness could fabricate a truth seal and slash an honest defender (or
//! save a fraudster). The spec now takes the MAJORITY seal of three independent witnesses, and
//! with no majority there is NO verdict -- the dispute stays open and, if nobody ever agrees,
//! settles by expiry FOR the defender (no proof, no slash). This transcribes the quorum and
//! pins: majority is permutation-invariant, one corrupt witness can never change the outcome in
//! EITHER direction, no-consensus moves no bonds, and the quorum verdict composes with the
//! settlement layer exactly like a directly-resolved one.

const DEFENDER_HONEST: u32 = 1;
const DEFENDER_LIED: u32 = 2;
const VERDICT_NONE: u32 = 0;

fn resolve(defender_seal: u32, truth_seal: u32) -> u32 {
    if defender_seal == truth_seal {
        DEFENDER_HONEST
    } else {
        DEFENDER_LIED
    }
}
fn witness_majority(s0: u32, s1: u32, s2: u32) -> u32 {
    if s0 == s1 {
        return s0;
    }
    if s0 == s2 {
        return s0;
    }
    if s1 == s2 {
        return s1;
    }
    0
}
fn witness_verdict(defender_seal: u32, s0: u32, s1: u32, s2: u32) -> u32 {
    let truth = witness_majority(s0, s1, s2);
    if truth == 0 {
        return VERDICT_NONE;
    }
    resolve(defender_seal, truth)
}
fn defender_bond_after(verdict: u32, d_stake: u32, c_stake: u32) -> u32 {
    if verdict == DEFENDER_HONEST {
        d_stake + c_stake
    } else if verdict == DEFENDER_LIED {
        0
    } else {
        d_stake // VERDICT_NONE: nothing moves
    }
}

#[test]
fn the_majority_is_permutation_invariant() {
    let (t, x) = (0xAAAA_u32, 0xDEAD_u32);
    for (a, b, c) in [(t, t, x), (t, x, t), (x, t, t)] {
        assert_eq!(witness_majority(a, b, c), t, "2-of-3 majority in any order");
        assert_eq!(
            witness_verdict(t, a, b, c),
            DEFENDER_HONEST,
            "verdict order-invariant (honest)"
        );
        assert_eq!(
            witness_verdict(0xBAD0, a, b, c),
            DEFENDER_LIED,
            "verdict order-invariant (lie)"
        );
    }
}

#[test]
fn one_corrupt_witness_can_never_change_the_outcome() {
    let truth = 0x600D_5EA1_u32;
    // Every position and every forged value: the majority still speaks the truth.
    for pos in 0..3 {
        for forged in [0u32, truth ^ 1, 0xFFFF_FFFF] {
            let mut seals = [truth; 3];
            seals[pos] = forged;
            assert_eq!(
                witness_verdict(truth, seals[0], seals[1], seals[2]),
                DEFENDER_HONEST,
                "a framing witness at position {pos} cannot slash an honest defender"
            );
            assert_eq!(
                witness_verdict(0xBAD0, seals[0], seals[1], seals[2]),
                DEFENDER_LIED,
                "a colluding witness at position {pos} cannot save a fraudster"
            );
        }
    }
}

#[test]
fn no_consensus_produces_no_verdict_and_moves_no_bonds() {
    let v = witness_verdict(0xAAAA, 0x1111, 0x2222, 0x3333);
    assert_eq!(v, VERDICT_NONE, "three disagreeing witnesses prove nothing");
    assert_eq!(
        defender_bond_after(v, 150, 100),
        150,
        "no quorum, no bond movement -- the dispute stays open toward expiry"
    );
}

#[test]
fn the_quorum_verdict_composes_with_settlement_like_a_direct_resolve() {
    // Same seal set, defender honest vs lying: the quorum verdict drives the same
    // bond consequences the direct resolve() would.
    let (s0, s1, s2) = (0xAAAA, 0xAAAA, 0xDEAD);
    let honest = witness_verdict(0xAAAA, s0, s1, s2);
    let lied = witness_verdict(0xBAD0, s0, s1, s2);
    assert_eq!(honest, resolve(0xAAAA, 0xAAAA));
    assert_eq!(lied, resolve(0xBAD0, 0xAAAA));
    assert_eq!(defender_bond_after(honest, 150, 100), 250);
    assert_eq!(defender_bond_after(lied, 150, 100), 0);
}

#[test]
fn a_truth_seal_of_zero_is_indistinguishable_from_no_quorum_and_stays_safe() {
    // Edge: if all three witnesses report seal 0 (e.g. an all-zero recompute),
    // witness_majority returns 0 which reads as "no quorum" -- the SAFE direction
    // (no slash on a degenerate seal), never a spurious verdict.
    assert_eq!(witness_verdict(0, 0, 0, 0), VERDICT_NONE);
    assert_eq!(witness_verdict(0xAAAA, 0, 0, 0), VERDICT_NONE);
}
