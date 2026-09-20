//! payout_no_over_issuance -- a CI-executed guard for the money-distribution layer. specs/
//! tri_compute_payout.t27 composes reputation weighting with the pool split and carries subtle
//! saturation / u64-widening guards against overflow, but its assertions live only in spec `test`
//! blocks, which are not compiled into `cargo test`. So the property that actually protects the
//! treasury -- reputation-weighted shares NEVER over-issue (sum <= pool), and the saturation guards
//! prevent a u32 wrap that would corrupt the split -- had no CI coverage. This transcribes the three
//! functions verbatim and pins those properties, including the exact wrap values the guards prevent.

const U32_MAX: u64 = 4294967295;

/// Effective weight = raw_work * rep, SATURATING at u32 max (tri_compute_payout.weighted).
fn weighted(raw_work: u32, rep: u32) -> u32 {
    let prod = (raw_work as u64) * (rep as u64);
    if prod > U32_MAX {
        U32_MAX as u32
    } else {
        prod as u32
    }
}

/// Saturating sum of three weights (tri_compute_payout.total_weighted3).
fn total_weighted3(w0: u32, w1: u32, w2: u32) -> u32 {
    let sum = (w0 as u64) + (w1 as u64) + (w2 as u64);
    if sum > U32_MAX {
        U32_MAX as u32
    } else {
        sum as u32
    }
}

/// Floor-div share of the pool by weight, u64 intermediate, empty-round guarded
/// (tri_compute_payout.payout).
fn payout(total_pool: u32, my_weighted: u32, total_weighted: u32) -> u32 {
    if total_weighted == 0 {
        0
    } else {
        let num = (total_pool as u64) * (my_weighted as u64);
        (num / (total_weighted as u64)) as u32
    }
}

#[test]
fn reputation_weighted_split_matches_the_spec() {
    let (w0, w1, w2) = (weighted(16, 1000), weighted(16, 500), weighted(16, 250));
    let tw = total_weighted3(w0, w1, w2);
    assert_eq!(tw, 28000, "16000+8000+4000");
    let (s0, s1, s2) = (
        payout(1000, w0, tw),
        payout(1000, w1, tw),
        payout(1000, w2, tw),
    );
    assert_eq!(
        (s0, s1, s2),
        (571, 285, 142),
        "rep 1000/500/250 -> 571/285/142"
    );
    assert!(
        s0 > s1 && s1 > s2,
        "higher reputation earns more for equal work"
    );
}

#[test]
fn shares_never_over_issue_across_a_sweep() {
    // The treasury-protecting invariant: floor-div weighted shares sum to at most the pool, for
    // every mix of pool, work, and reputation -- never more (floor loses dust; it can never gain).
    for &pool in &[0u32, 1, 1000, 1_000_000, U32_MAX as u32] {
        for &(r0, r1, r2) in &[
            (1000u32, 500, 250),
            (1000, 1000, 1000),
            (0, 0, 1),
            (1000, 1, 0),
        ] {
            for &work in &[1u32, 16, 48, 100_000] {
                let (w0, w1, w2) = (weighted(work, r0), weighted(work, r1), weighted(work, r2));
                let tw = total_weighted3(w0, w1, w2);
                let sum = (payout(pool, w0, tw) as u64)
                    + (payout(pool, w1, tw) as u64)
                    + (payout(pool, w2, tw) as u64);
                assert!(
                    sum <= pool as u64,
                    "over-issuance: sum {} > pool {}",
                    sum,
                    pool
                );
            }
        }
    }
}

#[test]
fn the_saturation_guard_prevents_a_u32_wrap() {
    // 5_000_000 * 1000 = 5e9 > 2^32. The guard saturates to u32 max; a bare u32 multiply would WRAP
    // to 705_032_704 -- a garbage weight that dominates and corrupts the proportional split.
    assert_eq!(
        weighted(5_000_000, 1000),
        U32_MAX as u32,
        "overflowing weight saturates, no wrap"
    );
    let bare_wrap = (5_000_000u32).wrapping_mul(1000);
    assert_eq!(bare_wrap, 705_032_704, "the wrap the guard prevents");
    assert_ne!(
        weighted(5_000_000, 1000),
        bare_wrap,
        "saturated value is NOT the wrapped garbage"
    );
    // Just under the ceiling stays exact.
    assert_eq!(
        weighted(4_294_967, 1000),
        4_294_967_000,
        "sub-ceiling weight is exact"
    );
}

#[test]
fn the_u64_intermediate_keeps_large_payouts_exact() {
    // 1e6 pool * 16000 weighted = 1.6e10 > 2^32. The u64 numerator floor-divides exactly to 666666;
    // a bare u32 product would wrap to 3_115_098_112 and yield a garbage 129_795 share.
    assert_eq!(
        payout(1_000_000, 16000, 24000),
        666666,
        "large pool*weighted is exact"
    );
    assert_eq!(payout(1_000_000, 8000, 24000), 333333, "second share exact");
    assert_eq!(
        payout(1_000_000, 16000, 24000) + payout(1_000_000, 8000, 24000),
        999999,
        "no over-issuance at scale"
    );
    let bare_num = (1_000_000u32).wrapping_mul(16000); // 1.6e10 mod 2^32
    assert_eq!(
        bare_num / 24000,
        129_795,
        "the garbage share the u64 widening prevents"
    );
}

#[test]
fn zero_reputation_and_empty_round_are_safe() {
    assert_eq!(weighted(48, 0), 0, "no reputation => zero weight");
    assert_eq!(payout(1000, 0, 28000), 0, "zero weight => zero payout");
    assert_eq!(
        payout(1000, 16000, 0),
        0,
        "empty round pays nobody, no divide-by-zero"
    );
}
