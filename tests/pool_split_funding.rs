//! pool_split_funding -- CI guard for the base pool split and its FUNDING conservation (specs/
//! tri_compute_pool.t27), the layer payout (#266) builds on. compute_ring_invariants covers only
//! balance_after_pool_settle; the split itself (pool_share, no-over-issuance), the anti-inflation
//! funding invariant (total payouts never exceed total deposits -- the pool is prepaid, not minted),
//! and the rung-proportionality-via-width (no double-counting) had no CI twin. This transcribes the
//! pool functions and pins them, including the u64 mulDiv that keeps the split exact at scale.

const U32_MAX: u64 = 4_294_967_295;

fn total_work3(w0: u32, w1: u32, w2: u32) -> u32 {
    let sum = (w0 as u64) + (w1 as u64) + (w2 as u64);
    if sum > U32_MAX {
        U32_MAX as u32
    } else {
        sum as u32
    }
}
fn pool_share(total_pool: u32, my_work: u32, total: u32) -> u32 {
    if total == 0 {
        0
    } else {
        let num = (total_pool as u64) * (my_work as u64);
        (num / (total as u64)) as u32
    }
}
fn pool_after_deposit(pool: u32, amount: u32) -> u32 {
    let sum = pool.wrapping_add(amount);
    if sum < pool {
        0xFFFF_FFFF
    } else {
        sum
    }
}
fn payout_capped(pool: u32, requested: u32) -> u32 {
    requested.min(pool)
}
fn pool_after_payout(pool: u32, requested: u32) -> u32 {
    pool.saturating_sub(requested)
}
fn balance_after_pool_settle(prev_balance: u32, pool: u32, reward: u32) -> u32 {
    prev_balance.saturating_add(payout_capped(pool, reward))
}

#[test]
fn the_split_is_proportional_with_floor_division() {
    assert_eq!(pool_share(1000, 16, 96), 166, "16/96 of 1000 (floor)");
    assert_eq!(pool_share(1000, 32, 96), 333, "32/96 of 1000 (floor)");
    assert_eq!(pool_share(1000, 48, 96), 500, "48/96 of 1000 (floor)");
    assert_eq!(
        pool_share(1000, 0, 96),
        0,
        "a node with no work earns nothing"
    );
    assert_eq!(
        pool_share(1000, 0, 0),
        0,
        "an empty round pays zero, no divide-by-zero"
    );
    assert!(
        pool_share(1000, 48, 96) > pool_share(1000, 16, 96),
        "more work, bigger share"
    );
}

#[test]
fn the_shares_never_over_issue_across_a_sweep() {
    // Floor-div shares sum to at most the pool; the remainder dust is simply not minted.
    for &pool in &[0u32, 1, 1000, 1_000_000] {
        for &(w0, w1, w2) in &[(16u32, 32, 48), (1, 1, 1), (64, 16, 0), (100_000, 1, 7)] {
            let total = total_work3(w0, w1, w2);
            let sum = (pool_share(pool, w0, total) as u64)
                + (pool_share(pool, w1, total) as u64)
                + (pool_share(pool, w2, total) as u64);
            assert!(sum <= pool as u64, "over-issuance: {sum} > pool {pool}");
        }
    }
    // The canonical case: 166+333+500 = 999 <= 1000.
    assert_eq!(
        pool_share(1000, 16, 96) + pool_share(1000, 32, 96) + pool_share(1000, 48, 96),
        999,
        "floor under-issues by the dust remainder"
    );
}

#[test]
fn the_split_is_rung_proportional_through_width_with_no_double_count() {
    // work == summed GF width, which already encodes the rung, so a GF-T64 node (width 64) earns 4x
    // a GF-T16 node (width 16) -- exactly the width/rung ratio, with NO extra rung premium. A separate
    // rung multiplier here would double-count the rung that width already carries.
    assert_eq!(pool_share(1000, 64, 80), 800, "GF-T64 earns 64/80");
    assert_eq!(pool_share(1000, 16, 80), 200, "GF-T16 earns 16/80");
    assert_eq!(
        pool_share(1000, 64, 80),
        4 * pool_share(1000, 16, 80),
        "GF-T64:GF-T16 = 4:1 = the width ratio"
    );
    assert_eq!(pool_share(1000, 32, 40), 800, "GF-T32 earns 32/40");
    assert_eq!(
        pool_share(1000, 8, 40),
        200,
        "GF-T8 earns 8/40 = 1/4 of GF-T32"
    );
}

#[test]
fn total_payouts_never_exceed_total_deposits() {
    // The anti-inflation invariant: the pool is prepaid; payouts draw it down and can never exceed
    // what was funded. Fund 1000, pay the three proportional shares; the pool ends at the floor dust.
    let p0 = pool_after_deposit(0, 1000);
    assert_eq!(pool_after_deposit(1000, 500), 1500, "deposits accumulate");
    let p1 = pool_after_payout(p0, pool_share(1000, 16, 96));
    let p2 = pool_after_payout(p1, pool_share(1000, 32, 96));
    let p3 = pool_after_payout(p2, pool_share(1000, 48, 96));
    assert_eq!(
        (p1, p2, p3),
        (834, 501, 1),
        "pool drawn down 1000 -> 834 -> 501 -> 1"
    );
    assert_eq!(
        p3,
        1000 - (166 + 333 + 500),
        "pool end == deposit - total payouts, exactly"
    );
    // An over-draw is capped at the funded balance and drains to zero, never negative.
    assert_eq!(payout_capped(100, 300), 100, "over-draw capped at the pool");
    assert_eq!(
        pool_after_payout(100, 300),
        0,
        "over-draw drains to zero, not negative"
    );
}

#[test]
fn pool_funded_settle_moves_value_without_minting() {
    // The executor gains exactly what the pool loses -> balance + pool is invariant across the settle.
    for &(bal, pool, reward) in &[(500u32, 1000u32, 300u32), (500, 100, 300), (0, 0, 50)] {
        let credit = payout_capped(pool, reward);
        let bal2 = balance_after_pool_settle(bal, pool, reward);
        let pool2 = pool_after_payout(pool, reward);
        assert_eq!(
            bal2,
            bal + credit,
            "executor credited exactly the capped reward"
        );
        assert_eq!(
            bal2 as u64 + pool2 as u64,
            bal as u64 + pool as u64,
            "balance + pool conserved across settle (b={bal} p={pool} r={reward})"
        );
    }
}

#[test]
fn the_u64_widening_keeps_the_split_exact_at_scale() {
    // 1e6 pool * 16000 work = 1.6e10 > 2^32. u64 floor-divides to 666666; a bare u32 product wraps to
    // 3_115_098_112 and yields a garbage 129_795 share, breaking no-over-issuance at scale.
    assert_eq!(
        pool_share(1_000_000, 16000, 24000),
        666666,
        "exact at scale"
    );
    assert_eq!(
        pool_share(1_000_000, 8000, 24000),
        333333,
        "second share exact"
    );
    assert_eq!(
        pool_share(1_000_000, 16000, 24000) + pool_share(1_000_000, 8000, 24000),
        999999,
        "no over-issuance at scale"
    );
    let bare = (1_000_000u32).wrapping_mul(16000) / 24000;
    assert_eq!(bare, 129_795, "the garbage share the u64 widening prevents");
    // total_work3 saturates so a wrapped total cannot put `total` below my_work and over-issue.
    assert_eq!(
        total_work3(4_000_000_000, 400_000_000, 0),
        U32_MAX as u32,
        "sum > 2^32 saturates"
    );
    assert!(
        pool_share(
            1000,
            3_000_000_000,
            total_work3(3_000_000_000, 3_000_000_000, 3_000_000_000)
        ) <= 1000,
        "a saturated total keeps the share within the pool"
    );
}
