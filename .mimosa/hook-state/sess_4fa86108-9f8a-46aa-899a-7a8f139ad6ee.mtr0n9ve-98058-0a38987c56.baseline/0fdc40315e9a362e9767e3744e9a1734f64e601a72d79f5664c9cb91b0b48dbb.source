//! ledger_mix32_structure -- CI guard for the tri_ledger state-root chain (specs/tri_ledger.t27),
//! the LAST mix32 gap in docs/CI_GUARD_MAP.md. The hash is the non-cryptographic mix32 (the real
//! tamper-evident settlement chain is guarded with sha2 in gft_ledger_settlement), but the STRUCTURE
//! the spec claims -- a deterministic genesis-bound state chain, order-sensitive and tamper-evident
//! in every round input, append-only, with a saturating balance tally -- must hold. This transcribes
//! the chain (spec `test`/`invariant` blocks are only parse/typechecked by t27c, never executed in
//! CI) and pins those structural properties, mirroring merkle_mix32_structure for tri_merkle.

const LEDGER_GENESIS: u32 = 0x5452_4C47; // "TRLG"

fn rotl(x: u32, k: u32) -> u32 {
    x.rotate_left(k)
}
fn mix32(x: u32) -> u32 {
    let a = x ^ (x >> 16);
    let b = a.wrapping_add(a << 3);
    let c = b ^ (b >> 11);
    let d = c.wrapping_add(c << 15);
    d ^ (d >> 16)
}
/// Saturating balance tally: the accumulated reward never wraps down.
fn balance_add(bal: u32, reward: u32) -> u32 {
    bal.saturating_add(reward)
}
/// Fold one round into the evolving state root (order-sensitive, binds prior state + round).
fn state_step(prev_state: u32, round_root: u32, epoch: u32) -> u32 {
    mix32(prev_state ^ mix32(round_root ^ rotl(epoch, 13)))
}
fn chain3(rr0: u32, e0: u32, rr1: u32, e1: u32, rr2: u32, e2: u32) -> u32 {
    let s0 = state_step(LEDGER_GENESIS, rr0, e0);
    let s1 = state_step(s0, rr1, e1);
    state_step(s1, rr2, e2)
}
fn verify_chain3(rr0: u32, e0: u32, rr1: u32, e1: u32, rr2: u32, e2: u32, claimed: u32) -> bool {
    chain3(rr0, e0, rr1, e1, rr2, e2) == claimed
}

#[test]
fn the_honest_chain_verifies_and_a_wrong_claimed_root_is_rejected() {
    // The spec's own KAT: recompute the 3-round chain from genesis, accept the true root only.
    let s2 = chain3(0x1111, 1, 0x2222, 2, 0x3333, 3);
    assert!(
        verify_chain3(0x1111, 1, 0x2222, 2, 0x3333, 3, s2),
        "honest chain verifies"
    );
    assert!(
        !verify_chain3(0x1111, 1, 0x2222, 2, 0x3333, 3, s2 ^ 1),
        "wrong root rejected"
    );
    assert_eq!(
        s2,
        chain3(0x1111, 1, 0x2222, 2, 0x3333, 3),
        "the chain is deterministic"
    );
}

#[test]
fn every_round_input_is_tamper_evident() {
    // Flipping one bit in ANY of the six round inputs changes the final state root.
    let base = chain3(0x1111, 1, 0x2222, 2, 0x3333, 3);
    let tampered = [
        chain3(0x1111 ^ 1, 1, 0x2222, 2, 0x3333, 3),
        chain3(0x1111, 1 ^ 1, 0x2222, 2, 0x3333, 3),
        chain3(0x1111, 1, 0x2222 ^ 1, 2, 0x3333, 3),
        chain3(0x1111, 1, 0x2222, 2 ^ 1, 0x3333, 3),
        chain3(0x1111, 1, 0x2222, 2, 0x3333 ^ 1, 3),
        chain3(0x1111, 1, 0x2222, 2, 0x3333, 3 ^ 1),
    ];
    for (i, t) in tampered.iter().enumerate() {
        assert_ne!(
            *t, base,
            "tampering with round input {i} must change the state root"
        );
    }
}

#[test]
fn rounds_cannot_be_reordered_and_the_chain_binds_the_genesis() {
    let base = chain3(0x1111, 1, 0x2222, 2, 0x3333, 3);
    // Swapping two rounds (root+epoch travel together) changes the final root.
    assert_ne!(
        chain3(0x2222, 2, 0x1111, 1, 0x3333, 3),
        base,
        "reordered rounds detected"
    );
    // The same rounds folded from a different genesis give a different root.
    let alt0 = state_step(LEDGER_GENESIS ^ 1, 0x1111, 1);
    let alt1 = state_step(alt0, 0x2222, 2);
    assert_ne!(
        state_step(alt1, 0x3333, 3),
        base,
        "the chain is genesis-bound"
    );
}

#[test]
fn the_chain_is_append_only() {
    // Each appended round moves the root: a truncated history can never claim the full root,
    // and extending a chain never returns to a previous state on these vectors.
    let s0 = state_step(LEDGER_GENESIS, 0x1111, 1);
    let s1 = state_step(s0, 0x2222, 2);
    let s2 = state_step(s1, 0x3333, 3);
    assert_ne!(s0, LEDGER_GENESIS, "round 1 moves the root");
    assert_ne!(s1, s0, "round 2 moves the root");
    assert_ne!(s2, s1, "round 3 moves the root");
    assert!(
        !verify_chain3(0x1111, 1, 0x2222, 2, 0x3333, 3, s1),
        "a truncated root is rejected"
    );
}

#[test]
fn a_one_bit_round_tamper_avalanches_across_the_state_root() {
    // mix32 is not cryptographic, but the structure must diffuse a one-bit tamper well past
    // one bit -- otherwise a root would leak how it was tampered.
    let base = chain3(0x1111, 1, 0x2222, 2, 0x3333, 3);
    let t = chain3(0x1111 ^ 1, 1, 0x2222, 2, 0x3333, 3);
    assert!(
        (base ^ t).count_ones() >= 8,
        "a one-bit tamper flips at least 8 root bits"
    );
}

#[test]
fn the_balance_tally_saturates_and_never_wraps() {
    // The spec's balance KAT plus the saturation edge: the tally is monotone, never wraps down.
    let b0 = balance_add(0, 713);
    let b1 = balance_add(b0, 258);
    let b2 = balance_add(b1, 27);
    assert_eq!((b0, b1, b2), (713, 971, 998), "balances accumulate");
    assert_eq!(
        balance_add(0xFFFF_FFF0, 0x100),
        0xFFFF_FFFF,
        "an overflowing add saturates"
    );
    assert_eq!(
        balance_add(0xFFFF_FFFF, 1),
        0xFFFF_FFFF,
        "the cap is absorbing"
    );
    assert!(
        balance_add(0xFFFF_FFF0, 0x100) >= 0xFFFF_FFF0,
        "the tally never wraps down"
    );
}
