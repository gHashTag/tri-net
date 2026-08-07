//! a2a_mesh_antireplay -- a result RE-FORWARDED over the mesh cannot double-settle. Mesh
//! forwarding is payload-transparent (a2a_over_mesh_integrity / mesh_protocol_stack), which
//! means a relay can also REPLAY a delivered datagram byte-for-byte -- so payload integrity
//! is not enough; freshness must hold too. The A2A task_id watermark
//! (tri_a2a.next_watermark_settled) rejects a replay: a result whose task_id does not exceed
//! the highest already-settled id settles nothing and does not move the mark, no matter how
//! many hops it travelled. This proves the anti-replay layer survives mesh transport.

// ---- task_id freshness / watermark (tri_a2a) ----
fn is_fresh(task_id: u32, last_settled: u32) -> bool {
    task_id > last_settled
}
fn next_watermark_settled(task_id: u32, last_settled: u32, settled: u32) -> u32 {
    if settled == 1 && task_id > last_settled {
        task_id
    } else {
        last_settled
    }
}

// ---- mesh delivery (payload-transparent; #237): the task_id arrives unchanged over N hops.
const MAX_HOPS: u8 = 3;
fn deliver_task_id(start_ttl: u8, hops: u32, task_id: u32) -> Option<u32> {
    if hops > (start_ttl as u32) {
        None // TTL expiry drops it
    } else {
        Some(task_id) // transparent forward: task_id unchanged
    }
}

/// One settlement step at a node: if a fresh result is delivered, credit its reward and
/// advance the watermark; a stale (replayed) or dropped result changes nothing.
/// Returns (new_balance, new_watermark).
fn settle_step(balance: u32, watermark: u32, delivered: Option<u32>, reward: u32) -> (u32, u32) {
    match delivered {
        Some(task_id) if is_fresh(task_id, watermark) => (
            balance + reward,
            next_watermark_settled(task_id, watermark, 1),
        ),
        _ => (balance, watermark), // stale replay or TTL-dropped -> no-op
    }
}

#[test]
fn first_delivery_settles_and_advances_the_watermark() {
    let (bal, wm) = settle_step(1000, 4, deliver_task_id(MAX_HOPS, 2, 5), 64);
    assert_eq!(bal, 1064, "a fresh result over the mesh settles its reward");
    assert_eq!(wm, 5, "the watermark advances to the settled task id");
}

#[test]
fn a_multi_hop_replay_cannot_double_settle() {
    // First honest delivery of task 5.
    let (bal1, wm1) = settle_step(1000, 4, deliver_task_id(MAX_HOPS, 2, 5), 64);
    assert_eq!((bal1, wm1), (1064, 5));
    // A relay re-forwards the SAME datagram (byte-identical, task_id 5) over the mesh -- even
    // across the full hop budget, the payload arrives intact but is now STALE (5 !> 5).
    let replay = deliver_task_id(MAX_HOPS, MAX_HOPS as u32, 5);
    assert_eq!(
        replay,
        Some(5),
        "the replayed datagram still delivers (payload-transparent)"
    );
    let (bal2, wm2) = settle_step(bal1, wm1, replay, 64);
    assert_eq!(bal2, 1064, "the replay settles NOTHING -- no double credit");
    assert_eq!(wm2, 5, "the watermark holds; a replay cannot advance it");
    assert!(
        !is_fresh(5, wm1),
        "task 5 is not fresh once its own id is the watermark"
    );
}

#[test]
fn a_later_task_still_settles_after_a_replay_attempt() {
    // Replays must not stale-block legitimate higher-id work.
    let (bal1, wm1) = settle_step(1000, 4, deliver_task_id(MAX_HOPS, 1, 5), 64); // task 5
    let (bal2, wm2) = settle_step(bal1, wm1, deliver_task_id(MAX_HOPS, 1, 5), 64); // replay 5 -> no-op
    assert_eq!((bal2, wm2), (1064, 5), "replay is a no-op");
    let (bal3, wm3) = settle_step(bal2, wm2, deliver_task_id(MAX_HOPS, 1, 6), 64); // fresh task 6
    assert_eq!(bal3, 1128, "a genuinely newer task still settles");
    assert_eq!(wm3, 6, "watermark advances to 6");
}
