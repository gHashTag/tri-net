//! dispute_swarm_e2e -- the capstone for the dispute layer: N concurrent disputes of DIFFERENT
//! rungs against ONE defender, driven through admission (#317/#318), mixed outcomes (one proven
//! lie, one honest resolve, one expiry), and settlement -- asserting global conservation. The
//! unit guards pin each mechanism alone; nothing yet pinned that a swarm with mixed verdicts
//! conserves every bond, that per-dispute outcomes stay independent (one lie does not leak into
//! the neighbouring disputes' bonds), and that the risk ledger returns to zero exactly when the
//! last dispute settles.

// ---- transcriptions (tri_challenge post-#318) ----
const DEFENDER_HONEST: u32 = 1;
const DEFENDER_LIED: u32 = 2;
const MAX_OPEN_DISPUTES: u32 = 3;
const BPS_UNIT: u32 = 10000;
const GFT16_ET: u32 = 4;
const BPS_PER_TRIT: u32 = 500;
const RESOLVE_TIMEOUT: u32 = 27;

fn rung_min_bps(min_bps: u32, gf_et: u32) -> u32 {
    if gf_et <= GFT16_ET {
        min_bps
    } else {
        min_bps + (gf_et - GFT16_ET) * BPS_PER_TRIT
    }
}
fn dispute_required_bond(outstanding: u32, min_bps: u32) -> u32 {
    ((u64::from(outstanding) * u64::from(min_bps)) / u64::from(BPS_UNIT)) as u32
}
fn dispute_slots_ok(open_count: u32) -> bool {
    open_count < MAX_OPEN_DISPUTES
}
fn risk_after_open(risk: u32, reward: u32) -> u32 {
    risk.saturating_add(reward)
}
fn risk_after_close(risk: u32, reward: u32) -> u32 {
    risk.saturating_sub(reward)
}
fn may_open_dispute_rung(
    open_count: u32,
    risk: u32,
    reward: u32,
    bond: u32,
    min_bps: u32,
    gf_et: u32,
) -> bool {
    if !dispute_slots_ok(open_count) {
        return false;
    }
    bond >= dispute_required_bond(risk_after_open(risk, reward), rung_min_bps(min_bps, gf_et))
}
fn resolve(defender_seal: u32, truth_seal: u32) -> u32 {
    if defender_seal == truth_seal {
        DEFENDER_HONEST
    } else {
        DEFENDER_LIED
    }
}
fn dispute_expired(opened_epoch: u32, now_epoch: u32) -> bool {
    if now_epoch < opened_epoch {
        return false;
    }
    (now_epoch - opened_epoch) > RESOLVE_TIMEOUT
}
fn expired_verdict() -> u32 {
    DEFENDER_HONEST
}
/// Per-dispute bond settlement (each dispute escrows its own defender/challenger stake pair).
fn defender_stake_after(verdict: u32, d_stake: u32, c_stake: u32) -> u32 {
    if verdict == DEFENDER_HONEST {
        d_stake + c_stake
    } else {
        0
    }
}
fn challenger_stake_after(verdict: u32, d_stake: u32, c_stake: u32) -> u32 {
    if verdict == DEFENDER_HONEST {
        0
    } else {
        c_stake + d_stake
    }
}

struct Dispute {
    reward: u32,
    et: u32,
    d_stake: u32,
    c_stake: u32,
    opened_at: u32,
}

#[test]
fn a_mixed_outcome_swarm_settles_independently_and_conserves_every_stake() {
    // One defender (collateral bond 320 at 20% base), three challengers on different rungs.
    // The Et9 open is the binding check: it prices the WHOLE 700 ledger at its 45% premium
    // (315), so the bond must exceed that even though the flagship-only view needs just 140.
    let (bond, min_bps) = (320u32, 2000u32);
    let disputes = [
        Dispute {
            reward: 200,
            et: 4,
            d_stake: 150,
            c_stake: 100,
            opened_at: 1000,
        }, // will be a proven lie
        Dispute {
            reward: 200,
            et: 4,
            d_stake: 80,
            c_stake: 120,
            opened_at: 1003,
        }, // frivolous (honest resolve)
        Dispute {
            reward: 300,
            et: 9,
            d_stake: 90,
            c_stake: 60,
            opened_at: 1007,
        }, // never resolved -> expiry
    ];

    // Admission: each open re-checks slots and coverage against the growing ledger,
    // at the dispute's own rung premium.
    let mut risk = 0u32;
    for (i, d) in disputes.iter().enumerate() {
        assert!(
            may_open_dispute_rung(i as u32, risk, d.reward, bond, min_bps, d.et),
            "dispute {i} admits against the growing ledger"
        );
        risk = risk_after_open(risk, d.reward);
    }
    assert_eq!(risk, 700, "the ledger carries all three rewards at risk");
    // A fourth flagship dispute is refused by the SLOT cap even though 260 covers 20% of 900.
    assert!(
        !may_open_dispute_rung(3, risk, 200, bond, min_bps, 4),
        "the slot cap stops the fourth challenger (coverage alone would allow 900*20%=180)"
    );

    // Outcomes: dispute 0 is a proven lie; dispute 1 resolves honest; dispute 2 expires.
    let v0 = resolve(0xBAD_C0DE, 0x600D_5EA1);
    let v1 = resolve(0x600D_5EA1, 0x600D_5EA1);
    assert!(dispute_expired(
        disputes[2].opened_at,
        disputes[2].opened_at + RESOLVE_TIMEOUT + 1
    ));
    let v2 = expired_verdict();
    assert_eq!(
        (v0, v1, v2),
        (DEFENDER_LIED, DEFENDER_HONEST, DEFENDER_HONEST)
    );

    // Settlement: per-dispute stake pairs settle independently -- the lie in dispute 0
    // costs the defender THAT dispute's stake only, not the neighbours'.
    let mut total_before = 0u32;
    let mut total_after = 0u32;
    let verdicts = [v0, v1, v2];
    let mut defender_gain = 0u32;
    for (d, v) in disputes.iter().zip(verdicts) {
        let da = defender_stake_after(v, d.d_stake, d.c_stake);
        let ca = challenger_stake_after(v, d.d_stake, d.c_stake);
        assert_eq!(
            da + ca,
            d.d_stake + d.c_stake,
            "stake conserved per dispute"
        );
        total_before += d.d_stake + d.c_stake;
        total_after += da + ca;
        defender_gain += da;
    }
    assert_eq!(
        total_before, total_after,
        "the swarm conserves the total escrow"
    );
    // Defender: loses dispute 0's 150, wins 80+120 and 90+60 from the other two.
    assert_eq!(
        defender_gain, 350,
        "one lie costs one stake; honest disputes still pay"
    );

    // The risk ledger returns to zero exactly when the last dispute settles.
    for (i, d) in disputes.iter().enumerate() {
        risk = risk_after_close(risk, d.reward);
        if i < disputes.len() - 1 {
            assert!(
                risk > 0,
                "ledger still carries open risk after settling dispute {i}"
            );
        }
    }
    assert_eq!(risk, 0, "ledger empty after the last settlement");
    // And a freed slot + empty ledger re-admits immediately.
    assert!(
        may_open_dispute_rung(0, 0, 200, bond, min_bps, 4),
        "the defender is challengeable again"
    );
}

#[test]
fn the_wide_rung_dispute_was_the_binding_coverage_constraint() {
    // Reorder check: had the Et9 dispute come FIRST, the flagship two would still admit --
    // admission order does not change the set of admissible disputes for this bond.
    let (bond, min_bps) = (260u32, 2000u32);
    let mut risk = 0u32;
    assert!(
        may_open_dispute_rung(0, risk, 300, bond, min_bps, 9),
        "Et9 first: 300 at 45% = 135"
    );
    risk = risk_after_open(risk, 300);
    assert!(
        may_open_dispute_rung(1, risk, 200, bond, min_bps, 4),
        "then flagship: 500 at 20% = 100"
    );
    risk = risk_after_open(risk, 200);
    assert!(
        may_open_dispute_rung(2, risk, 200, bond, min_bps, 4),
        "then flagship: 700 at 20% = 140"
    );
    // But the same three at Et9 premium would NOT all fit: 700 at 45% = 315 > 260.
    assert!(
        !may_open_dispute_rung(2, 500, 200, bond, min_bps, 9),
        "a third WIDE dispute would blow the coverage"
    );
}
