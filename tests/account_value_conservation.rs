//! account_value_conservation -- CI guard for the value-CONSERVATION invariants of the accounting
//! layer (specs/tri_compute_account.t27). compute_ring_invariants already pins the individual
//! saturation gates (bal_add_sat, finalize_checked, ...), but not the end-to-end property the spec
//! header promises: value is never MINTED or LEAKED across a lifecycle -- lock just relabels balance
//! as collateral, an honest settle->finalize moves the escrowed reward into spendable without
//! creating any, a clawback returns EXACTLY the reward to the pool, a slash removes EXACTLY the bond,
//! and pending == outstanding at every step. These conservation equalities had no CI coverage.
//!
//! Values are swept well below the u32 ceiling so exact conservation holds; the saturation boundary
//! (where bal_add_sat deliberately caps instead of wrapping) is a separate safety cap tested in
//! compute_ring_invariants.

// ---- tri_compute_account, transcribed verbatim ----
fn total(balance: u32, locked: u32) -> u32 {
    balance + locked
}
fn total3(balance: u32, locked: u32, pending: u32) -> u32 {
    balance + locked + pending
}
fn bal_after_lock(balance: u32, amt: u32) -> u32 {
    if amt <= balance {
        balance - amt
    } else {
        balance
    }
}
fn locked_after_lock(balance: u32, locked: u32, amt: u32) -> u32 {
    if amt <= balance {
        locked + amt
    } else {
        locked
    }
}
fn bal_add_sat(balance: u32, amount: u32) -> u32 {
    let sum = balance.wrapping_add(amount);
    if sum < balance {
        0xFFFF_FFFF
    } else {
        sum
    }
}
fn bal_after_finalize(balance: u32, pending: u32) -> u32 {
    bal_add_sat(balance, pending)
}
fn bal_after_clawback(balance: u32) -> u32 {
    balance
}
fn bal_after_slash(balance: u32) -> u32 {
    balance
}
fn pending_after_settle(pending: u32, reward: u32) -> u32 {
    let sum = pending.wrapping_add(reward);
    if sum < pending {
        0xFFFF_FFFF
    } else {
        sum
    }
}
fn outstanding_after_escrow(outstanding: u32, reward: u32) -> u32 {
    let sum = outstanding.wrapping_add(reward);
    if sum < outstanding {
        0xFFFF_FFFF
    } else {
        sum
    }
}
fn pending_after_release(pending: u32, reward: u32) -> u32 {
    // spec: reward <= pending ? pending - reward : 0 -- exactly saturating_sub.
    pending.saturating_sub(reward)
}
fn outstanding_after_release(outstanding: u32, reward: u32) -> u32 {
    outstanding.saturating_sub(reward)
}

// Sub-ceiling sweep values (no saturation).
const BALS: [u32; 4] = [0, 100, 50_000, 1_000_000];
const LOCKS: [u32; 3] = [0, 10, 25_000];
const AMTS: [u32; 4] = [0, 10, 100, 2_000_000]; // last one exceeds small balances (no-op lock)
const REWARDS: [u32; 4] = [0, 1, 500, 300_000];

#[test]
fn lock_relabels_value_without_creating_or_destroying_it() {
    // lock moves `amt` from balance to locked; total(balance+locked) is invariant, whether the
    // lock succeeds (amt <= balance) or is a guarded no-op (amt > balance).
    for &b in &BALS {
        for &l in &LOCKS {
            for &amt in &AMTS {
                let before = total(b, l);
                let after = total(bal_after_lock(b, amt), locked_after_lock(b, l, amt));
                assert_eq!(after, before, "lock changed total: b={b} l={l} amt={amt}");
            }
        }
    }
}

#[test]
fn an_honest_finalize_moves_the_reward_into_spendable_without_minting() {
    // State (balance, locked, pending=reward) after an optimistic settle; the window elapses with no
    // fraud, so finalize moves the escrowed reward into spendable. total3 is conserved and spendable
    // rises by EXACTLY the reward.
    for &b in &BALS {
        for &l in &LOCKS {
            for &r in &REWARDS {
                let before = total3(b, l, r);
                let bal2 = bal_after_finalize(b, r);
                let pending2 = pending_after_release(r, r); // the finalized reward leaves pending
                let after = total3(bal2, l, pending2);
                assert_eq!(after, before, "finalize minted/burned: b={b} l={l} r={r}");
                assert_eq!(bal2, b + r, "spendable rose by exactly the reward");
                assert_eq!(pending2, 0, "pending emptied on finalize");
            }
        }
    }
}

#[test]
fn a_clawback_returns_exactly_the_reward_to_the_pool() {
    // Fraud proven in-window: the pending reward reverts to the pool. Spendable is untouched, pending
    // empties, so the node's total3 drops by EXACTLY the reward (which the pool reclaims) -- no more.
    for &b in &BALS {
        for &l in &LOCKS {
            for &r in &REWARDS {
                let before = total3(b, l, r);
                let bal2 = bal_after_clawback(b);
                let pending2 = pending_after_release(r, r);
                let after = total3(bal2, l, pending2);
                assert_eq!(
                    before - after,
                    r,
                    "clawback moved != reward: b={b} l={l} r={r}"
                );
                assert_eq!(bal2, b, "spendable balance untouched by clawback");
            }
        }
    }
}

#[test]
fn a_slash_removes_exactly_the_bond_and_nothing_else() {
    // The locked bond leaves to the challenger; spendable balance is untouched, so the node's total
    // drops by EXACTLY the locked amount. (Conserved system-wide: the challenger gains that bond.)
    for &b in &BALS {
        for &l in &LOCKS {
            let before = total(b, l);
            let after = total(bal_after_slash(b), 0); // bond gone
            assert_eq!(before - after, l, "slash removed != bond: b={b} l={l}");
            assert_eq!(
                bal_after_slash(b),
                b,
                "spendable balance untouched by slash"
            );
        }
    }
}

#[test]
fn pending_equals_outstanding_through_settle_and_release() {
    // The escrow invariant pending == outstanding must survive BOTH an escrow (settle) and a release
    // (finalize/clawback). The two functions are byte-identical by construction; pin it end to end.
    for &start in &[0u32, 7, 40_000] {
        for &r in &REWARDS {
            let (mut pending, mut outstanding) = (start, start);
            pending = pending_after_settle(pending, r);
            outstanding = outstanding_after_escrow(outstanding, r);
            assert_eq!(
                pending, outstanding,
                "diverged after settle: start={start} r={r}"
            );
            pending = pending_after_release(pending, r);
            outstanding = outstanding_after_release(outstanding, r);
            assert_eq!(
                pending, outstanding,
                "diverged after release: start={start} r={r}"
            );
        }
    }
}
