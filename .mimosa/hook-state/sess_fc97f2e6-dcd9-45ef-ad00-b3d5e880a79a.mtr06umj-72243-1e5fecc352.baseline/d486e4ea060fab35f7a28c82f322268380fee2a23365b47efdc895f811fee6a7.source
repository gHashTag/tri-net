//! a2a_over_mesh_integrity -- an A2A compute result survives MULTI-HOP mesh forwarding
//! with its receipt integrity intact. The mesh (mesh_protocol_stack / mesh_routing)
//! forwards packets hop-by-hop, decrementing TTL and dropping at expiry (MAX_HOPS = 3);
//! the A2A datagram it carries ends in a signed receipt (tri_a2a_wire). These two layers
//! were specified separately -- nothing tied mesh forwarding to receipt integrity. This
//! models the join and proves three properties end-to-end (device -> node -> node ->
//! device):
//!   1. forwarding is PAYLOAD-TRANSPARENT -- a hop touches only the TTL, so the receipt
//!      leaf delivered after N hops equals the one sent;
//!   2. TTL expiry DROPS the packet -- a path longer than the TTL delivers NOTHING, never
//!      a silent partial / stale result;
//!   3. a hop that TAMPERS the receipt is DETECTED at the destination -- the delivered
//!      leaf no longer matches the executor's signed leaf (the signature binds integrity
//!      across every hop).

const MAX_HOPS: u8 = 3;

/// mesh_protocol_stack.decrement_ttl: ttl>0 -> (ttl-1, not-expired); ttl==0 -> expired.
fn decrement_ttl(ttl: u8) -> (u8, bool) {
    if ttl > 0 {
        (ttl - 1, false)
    } else {
        (ttl, true)
    }
}

/// One honest hop: decrement TTL, carry the receipt leaf UNCHANGED (payload-transparent).
fn forward(ttl: u8, leaf: u32) -> (u8, u32, bool) {
    let (nt, expired) = decrement_ttl(ttl);
    (nt, leaf, expired)
}

/// Deliver a datagram (ttl, receipt leaf) across `hops` honest hops.
/// Returns Some(delivered_leaf) if it arrives, None if a hop dropped it (TTL expired).
fn deliver(start_ttl: u8, hops: u32, leaf: u32) -> Option<u32> {
    let mut ttl = start_ttl;
    let mut l = leaf;
    for _ in 0..hops {
        let (nt, nl, expired) = forward(ttl, l);
        if expired {
            return None; // dropped at this hop -- no partial delivery
        }
        ttl = nt;
        l = nl;
    }
    Some(l)
}

/// Deliver where hop index `tamper_at` (0-based) flips the receipt leaf.
fn deliver_with_tamper(start_ttl: u8, hops: u32, leaf: u32, tamper_at: u32) -> Option<u32> {
    let mut ttl = start_ttl;
    let mut l = leaf;
    for h in 0..hops {
        let (nt, mut nl, expired) = forward(ttl, l);
        if expired {
            return None;
        }
        if h == tamper_at {
            nl ^= 0xDEAD_BEEF; // a relay rewrites the receipt bytes
        }
        ttl = nt;
        l = nl;
    }
    Some(l)
}

/// The destination's integrity check: the delivered receipt leaf must equal the executor's
/// signed leaf (models verifying the Ed25519 signature over the receipt digest).
fn integrity_ok(delivered: Option<u32>, signed_leaf: u32) -> bool {
    delivered == Some(signed_leaf)
}

#[test]
fn forwarding_is_payload_transparent() {
    let leaf = 0x1234_ABCD; // the executor's signed receipt leaf
    for hops in 1..=(MAX_HOPS as u32) {
        assert_eq!(
            deliver(MAX_HOPS, hops, leaf),
            Some(leaf),
            "after {hops} hop(s) the receipt leaf is unchanged"
        );
        assert!(
            integrity_ok(deliver(MAX_HOPS, hops, leaf), leaf),
            "integrity holds at {hops} hops"
        );
    }
}

#[test]
fn ttl_expiry_drops_the_packet() {
    let leaf = 0x1234_ABCD;
    // A path longer than the TTL delivers NOTHING (not a stale/partial result).
    assert_eq!(
        deliver(MAX_HOPS, (MAX_HOPS as u32) + 1, leaf),
        None,
        "4 hops on ttl=3 -> dropped"
    );
    assert!(
        !integrity_ok(deliver(MAX_HOPS, (MAX_HOPS as u32) + 1, leaf), leaf),
        "a dropped result is not accepted"
    );
    // A shorter TTL drops sooner -- exactly at the hop the TTL runs out.
    assert_eq!(deliver(1, 1, leaf), Some(leaf), "ttl=1 reaches 1 hop");
    assert_eq!(deliver(1, 2, leaf), None, "ttl=1 cannot make 2 hops");
    assert_eq!(
        deliver(0, 1, leaf),
        None,
        "ttl=0 is already expired -> immediate drop"
    );
}

#[test]
fn a_tampering_hop_is_detected_at_the_destination() {
    let signed = 0x1234_ABCD;
    // Any hop that rewrites the receipt yields a delivered leaf != the signed one.
    for t in 0..MAX_HOPS as u32 {
        let delivered = deliver_with_tamper(MAX_HOPS, MAX_HOPS as u32, signed, t);
        assert_ne!(
            delivered,
            Some(signed),
            "tamper at hop {t} changes the leaf"
        );
        assert!(
            !integrity_ok(delivered, signed),
            "the signed-leaf check rejects a tampered receipt (hop {t})"
        );
    }
    // The untampered baseline still verifies -- so rejection is specific to tampering.
    assert!(
        integrity_ok(deliver(MAX_HOPS, MAX_HOPS as u32, signed), signed),
        "honest multi-hop delivery verifies"
    );
}
