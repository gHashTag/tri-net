//! witness_economics -- CI guard for the quorum's incentive layer (specs/tri_challenge.t27).
//! A witness posts a stake to vote; minority voters forfeit into a pot split equally among the
//! majority (floor division, dust burnt, never minted); NO quorum refunds everyone (punishing a
//! 1-1-1 split would let an attacker grief honest witnesses by merely disagreeing); rewards come
//! ONLY from minority forfeits, so echoing an honest unanimous round pays nothing extra while
//! voting against a majority strictly loses. This transcribes the payout and pins conservation
//! across EVERY 3-witness seal configuration, the incentive ordering, and the griefing edges.

const NO_QUORUM: u32 = 0;

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
fn witness_is_majority(seal: u32, majority: u32) -> bool {
    majority != 0 && seal == majority
}
fn majority_count_3(s0: u32, s1: u32, s2: u32, majority: u32) -> u32 {
    [s0, s1, s2]
        .iter()
        .filter(|s| witness_is_majority(**s, majority))
        .count() as u32
}
fn minority_pot_3(s0: u32, s1: u32, s2: u32, majority: u32, stake: u32) -> u32 {
    (3 - majority_count_3(s0, s1, s2, majority)) * stake
}
fn witness_payout(voted: u32, s0: u32, s1: u32, s2: u32, stake: u32) -> u32 {
    let majority = witness_majority(s0, s1, s2);
    if majority == NO_QUORUM {
        return stake;
    }
    if witness_is_majority(voted, majority) {
        let pot = minority_pot_3(s0, s1, s2, majority, stake);
        return stake + pot / majority_count_3(s0, s1, s2, majority);
    }
    0
}

/// Total paid out to the three voters plus burnt dust must equal the three stakes.
fn round_total(s0: u32, s1: u32, s2: u32, stake: u32) -> (u32, u32) {
    let paid = witness_payout(s0, s0, s1, s2, stake)
        + witness_payout(s1, s0, s1, s2, stake)
        + witness_payout(s2, s0, s1, s2, stake);
    let dust = 3 * stake - paid;
    (paid, dust)
}

#[test]
fn every_seal_configuration_conserves_the_stakes() {
    // Enumerate all structural patterns over three seals from a 3-value alphabet:
    // unanimous, every 2-1 split, and all-distinct. Payouts never exceed the pool,
    // and dust is only ever a floor-division remainder (< majority count).
    let vals = [0xAAAA_u32, 0xBBBB, 0xCCCC];
    for &a in &vals {
        for &b in &vals {
            for &c in &vals {
                let (paid, dust) = round_total(a, b, c, 100);
                assert!(paid <= 300, "never mints ({a:X},{b:X},{c:X})");
                assert_eq!(paid + dust, 300, "stakes conserved ({a:X},{b:X},{c:X})");
                let maj = witness_majority(a, b, c);
                if maj == NO_QUORUM {
                    assert_eq!(dust, 0, "no quorum refunds exactly");
                } else {
                    assert!(
                        dust < majority_count_3(a, b, c, maj),
                        "dust is only a floor remainder"
                    );
                }
            }
        }
    }
}

#[test]
fn the_incentive_ordering_holds() {
    // Majority voter >= own stake; dissenter gets zero; unanimity pays no premium.
    let (t, x) = (0xAAAA_u32, 0xDEAD_u32);
    assert_eq!(
        witness_payout(t, t, t, t, 100),
        100,
        "unanimity: no free reward"
    );
    assert_eq!(
        witness_payout(t, t, t, x, 100),
        150,
        "majority gains the forfeit"
    );
    assert_eq!(witness_payout(x, t, t, x, 100), 0, "dissent strictly loses");
    assert!(
        witness_payout(t, t, t, x, 100) > witness_payout(t, t, t, t, 100),
        "catching a liar pays better than a quiet round"
    );
}

#[test]
fn no_quorum_refunds_everyone_griefing_gains_nothing() {
    // A griefer who forces 1-1-1 by disagreeing burns nobody -- and gains nothing.
    let (paid, dust) = round_total(0x1111, 0x2222, 0x3333, 100);
    assert_eq!((paid, dust), (300, 0), "full refund, no burn");
    for v in [0x1111u32, 0x2222, 0x3333] {
        assert_eq!(witness_payout(v, 0x1111, 0x2222, 0x3333, 100), 100);
    }
}

#[test]
fn dust_is_burnt_never_minted() {
    // 2-1 split with an odd stake: pot 101 splits as 50+50, 1 unit burns.
    let (t, x) = (0xAAAA_u32, 0xDEAD_u32);
    let m = witness_payout(t, t, t, x, 101);
    assert_eq!(m, 101 + 50, "floor share");
    let (paid, dust) = round_total(t, t, x, 101);
    assert_eq!(paid, 302, "two majority payouts, dissenter zero");
    assert_eq!(dust, 1, "the odd unit burns");
}
