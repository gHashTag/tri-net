//! a2a_mesh_drop_conservation -- a result DROPPED by the mesh (TTL expiry, no route) must
//! settle NOTHING: value is conserved across the transport boundary. Mesh forwarding drops a
//! packet whose path exceeds its TTL (mesh_protocol_stack, MAX_HOPS = 3); the a2a_over_mesh_
//! integrity oracle showed a dropped datagram delivers `None`. This ties that None to the
//! value layer: settlement credits a reward ONLY on an actually-delivered result, so a
//! TTL-drop never mints a reward, and the total (executor balance + undelivered rewards)
//! is conserved -- a lost packet is lost, not silently paid.

const MAX_HOPS: u8 = 3;

/// Mesh delivery outcome: Some(reward) if the result arrives within the TTL budget, else None.
fn deliver(start_ttl: u8, hops: u32, reward: u32) -> Option<u32> {
    if hops > (start_ttl as u32) {
        None // TTL expiry -> dropped
    } else {
        Some(reward)
    }
}

/// Settlement credits the reward ONLY on a delivered result; a dropped (None) result is a no-op.
fn settle(balance: u32, delivered: Option<u32>) -> u32 {
    match delivered {
        Some(reward) => balance + reward,
        None => balance,
    }
}

#[test]
fn a_delivered_result_settles_its_reward() {
    for hops in 1..=(MAX_HOPS as u32) {
        assert_eq!(
            settle(1000, deliver(MAX_HOPS, hops, 64)),
            1064,
            "delivered in {hops} hops -> paid"
        );
    }
}

#[test]
fn a_ttl_dropped_result_mints_nothing() {
    // A path longer than the TTL is dropped -> the reward is never credited.
    let dropped = deliver(MAX_HOPS, (MAX_HOPS as u32) + 1, 64);
    assert_eq!(dropped, None, "4 hops on ttl=3 -> dropped");
    assert_eq!(
        settle(1000, dropped),
        1000,
        "a TTL-dropped result settles nothing"
    );
}

#[test]
fn value_is_conserved_across_the_transport() {
    // Conservation: for a batch, executor balance + undelivered rewards == starting total.
    let reward = 64u32;
    let start_balance = 1000u32;
    // Three results: two delivered (3 and 1 hops), one dropped (5 hops on ttl=3).
    let d0 = deliver(MAX_HOPS, 3, reward); // Some
    let d1 = deliver(MAX_HOPS, 1, reward); // Some
    let d2 = deliver(MAX_HOPS, 5, reward); // None (dropped)
    let bal = settle(settle(settle(start_balance, d0), d1), d2);
    let paid = bal - start_balance;
    let undelivered: u32 = [d0, d1, d2].iter().filter(|d| d.is_none()).count() as u32 * reward;
    assert_eq!(
        paid,
        2 * reward,
        "exactly the two delivered rewards were paid"
    );
    assert_eq!(
        undelivered, reward,
        "exactly one reward was dropped (never minted)"
    );
    // Total accounted for: paid + undelivered == the whole batch's reward budget.
    assert_eq!(
        paid + undelivered,
        3 * reward,
        "no value created or destroyed at the boundary"
    );
}
