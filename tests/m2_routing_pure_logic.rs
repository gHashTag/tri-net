//! M2-prep pure-logic tests (host-only, no network I/O, no radios).
//!
//! Milestone context: M1 is scientifically closed on the Zynq platform
//! (see `smoke/M1_SCIENTIFIC_CLOSURE_2026-07-04.md`). M2 real-network stand-up
//! is blocked on the image-bake milestone (see `docs/IMAGE_BAKE_MILESTONE.md`)
//! because the stock ramfs rootfs wipes `/etc` on cold-boot and all three
//! boards share MAC `00:0a:35:00:01:22`.
//!
//! Until baked images exist, we cannot run a real 3-board mesh — but we CAN
//! keep tightening the pure-logic surface: TUN address allocation, wire
//! serialization boundaries, ETX ordering edge-cases, and path-ETX overflow.
//! Every assertion here runs on the dev host in `cargo test`, no `/dev/net/tun`,
//! no UDP, no radios. All claims are strictly `-sim`.
//!
//! Anchor: phi^2 + phi^-2 = 3.

use trios_mesh::routing::{EtxTable, NodeId};
use trios_mesh::router::{mesh_ip, node_of, DEFAULT_TTL};
use trios_mesh::wire::{FrameKind, Header};
use trios_mesh::discovery::Hello;
use std::net::Ipv4Addr;

// ---------------------------------------------------------------------------
// TUN allocation math: mesh_ip / node_of over the 10.42.0.0/24 subnet.
// The router.rs comment reserves NodeId 1..=254; 0 and 255 are outside range.
// ---------------------------------------------------------------------------

#[test]
fn mesh_ip_maps_first_and_last_valid_ids() {
    assert_eq!(mesh_ip(1), Ipv4Addr::new(10, 42, 0, 1));
    assert_eq!(mesh_ip(254), Ipv4Addr::new(10, 42, 0, 254));
}

#[test]
fn node_of_accepts_full_valid_range() {
    for id in 1u32..=254 {
        let ip = mesh_ip(id);
        assert_eq!(node_of(ip), Some(id), "roundtrip failed for id={id}");
    }
}

#[test]
fn node_of_rejects_network_and_broadcast() {
    // 10.42.0.0 = network, 10.42.0.255 = broadcast — both excluded per the
    // 1..=254 policy in router.rs.
    assert_eq!(node_of(Ipv4Addr::new(10, 42, 0, 0)), None);
    assert_eq!(node_of(Ipv4Addr::new(10, 42, 0, 255)), None);
}

#[test]
fn node_of_rejects_wrong_subnets() {
    // Anything outside 10.42.0.0/24 must return None so we do not accidentally
    // route Internet traffic into the mesh.
    assert_eq!(node_of(Ipv4Addr::new(192, 168, 0, 5)), None);
    assert_eq!(node_of(Ipv4Addr::new(10, 42, 1, 5)), None);
    assert_eq!(node_of(Ipv4Addr::new(10, 43, 0, 5)), None);
    assert_eq!(node_of(Ipv4Addr::new(11, 42, 0, 5)), None);
}

#[test]
fn mesh_ip_masks_high_bits() {
    // mesh_ip uses (id & 0xff) — so id=257 wraps to id=1's octet. This is a
    // documented property of the current mapping; the test pins it so a future
    // refactor cannot silently change the collision behaviour.
    assert_eq!(mesh_ip(257).octets()[3], 1);
    assert_eq!(mesh_ip(511).octets()[3], 255);
}

// ---------------------------------------------------------------------------
// Wire header serialization boundaries.
// ---------------------------------------------------------------------------

#[test]
fn header_all_kinds_roundtrip() {
    for &kind in &[FrameKind::Hello, FrameKind::Data] {
        let h = Header::new(kind, 0xDEAD_BEEF, 0xCAFE_BABE, DEFAULT_TTL);
        let parsed = Header::parse(&h.to_bytes()).expect("must parse");
        assert_eq!(parsed, h);
    }
}

#[test]
fn header_rejects_unknown_kind() {
    // kind=2..=255 are unassigned; parse must reject them so a future frame
    // type cannot be smuggled through the current parser.
    let mut bytes = Header::new(FrameKind::Data, 1, 2, 4).to_bytes();
    for bad in 2u8..=255 {
        bytes[1] = bad;
        assert!(
            Header::parse(&bytes).is_none(),
            "kind={bad} must be rejected"
        );
    }
}

#[test]
fn header_rejects_short_input() {
    let full = Header::new(FrameKind::Data, 1, 2, 3).to_bytes();
    for shrink in 0..Header::LEN {
        assert!(
            Header::parse(&full[..shrink]).is_none(),
            "truncated to {shrink} bytes must fail"
        );
    }
}

#[test]
fn header_ttl_extremes_roundtrip() {
    for &ttl in &[0u8, 1, DEFAULT_TTL, 255] {
        let h = Header::new(FrameKind::Data, 42, 43, ttl);
        assert_eq!(Header::parse(&h.to_bytes()), Some(h));
    }
}

#[test]
fn header_length_is_stable() {
    // If someone changes Header::LEN, every crypto AAD assumption breaks — pin
    // it here so the diff is loud.
    assert_eq!(Header::LEN, 11);
    let h = Header::new(FrameKind::Hello, 0, 0, 0);
    assert_eq!(h.to_bytes().len(), 11);
}

// ---------------------------------------------------------------------------
// HELLO wire serialization boundaries.
// Format is [src:4][seq:4][ts:8][n:1][heard: n*4][mac:16] = 17 + 4n bytes.
// ---------------------------------------------------------------------------

#[test]
fn hello_empty_heard_is_exactly_33_bytes() {
    let h = Hello::new(1, 1, 1, vec![], [0u8; 16]);
    assert_eq!(h.to_bytes().len(), 33, "17 header + 0 heard + 16 mac");
}

#[test]
fn hello_length_scales_linearly_with_heard() {
    for n in 0..=10 {
        let heard: Vec<NodeId> = (1..=n as u32).collect();
        let h = Hello::new(7, 1, 1, heard, [0u8; 16]);
        assert_eq!(h.to_bytes().len(), 33 + 4 * n);
    }
}

#[test]
fn hello_max_heard_255_roundtrips() {
    // Serializer caps at u8::MAX = 255 entries. Verify the boundary works
    // end-to-end so a fully saturated neighbor set does not corrupt the wire.
    let heard: Vec<NodeId> = (1..=255u32).collect();
    let h = Hello::new(7, 42, 100, heard.clone(), [0xABu8; 16]);
    let parsed = Hello::parse(&h.to_bytes()).expect("must parse");
    assert_eq!(parsed.heard.len(), 255);
    assert_eq!(parsed.heard, heard);
    assert_eq!(parsed.mac, [0xABu8; 16]);
}

#[test]
fn hello_overlong_heard_is_truncated_by_serializer() {
    // Serializer takes .min(u8::MAX) — an oversized Vec must silently truncate
    // rather than corrupt the length prefix. Pin the behaviour so it is not
    // accidentally changed.
    let heard: Vec<NodeId> = (1..=300u32).collect();
    let h = Hello::new(7, 1, 1, heard, [0u8; 16]);
    let bytes = h.to_bytes();
    // 17 header + 255 * 4 heard + 16 mac
    assert_eq!(bytes.len(), 17 + 255 * 4 + 16);
    let parsed = Hello::parse(&bytes).expect("must parse");
    assert_eq!(parsed.heard.len(), 255);
}

#[test]
fn hello_truncation_at_every_offset_rejected() {
    let h = Hello::new(7, 1, 1, vec![1, 2, 3], [0x11u8; 16]);
    let full = h.to_bytes();
    // Chop the mac by one byte at a time — no partial mac must ever parse.
    for chop in 1..=16 {
        assert!(
            Hello::parse(&full[..full.len() - chop]).is_none(),
            "chop={chop} must be rejected"
        );
    }
}

#[test]
fn hello_length_prefix_larger_than_buffer_rejected() {
    // Forge a length prefix that claims more heard entries than the buffer
    // holds. Parser must refuse rather than reading OOB.
    let h = Hello::new(7, 1, 1, vec![1, 2], [0u8; 16]);
    let mut bytes = h.to_bytes();
    bytes[16] = 200; // claim 200 entries where only 2 exist
    assert!(Hello::parse(&bytes).is_none());
}

#[test]
fn hello_reports_hearing_matches_membership() {
    let h = Hello::new(1, 1, 1, vec![10, 20, 30], [0u8; 16]);
    assert!(h.reports_hearing(20));
    assert!(!h.reports_hearing(40));
    let empty = Hello::new(1, 1, 1, vec![], [0u8; 16]);
    assert!(!empty.reports_hearing(1));
}

// ---------------------------------------------------------------------------
// ETX ordering and path-ETX arithmetic edge cases.
// ---------------------------------------------------------------------------

#[test]
fn best_next_hop_is_deterministic_under_ties() {
    // Two neighbors with identical ETX — min_by must pick one deterministically
    // and never flip between calls. This matters for stable routing decisions.
    let mut t = EtxTable::new(10);
    for _ in 0..20 {
        t.record(2, true, true);
        t.record(3, true, true);
    }
    let first = t.best_next_hop().unwrap().0;
    for _ in 0..50 {
        assert_eq!(t.best_next_hop().unwrap().0, first);
    }
}

#[test]
fn compute_path_etx_overflow_saturates_to_infinity() {
    let mut t = EtxTable::new(10);
    for _ in 0..20 {
        t.record(2, true, true);
    }
    // Advertised ETX above the 1_000_000 guard must saturate to +inf so
    // downstream comparisons treat it as unusable.
    assert!(t.compute_path_etx(2, 2_000_000.0).is_infinite());
}

#[test]
fn compute_path_etx_rejects_non_finite_advertised() {
    let mut t = EtxTable::new(10);
    for _ in 0..20 {
        t.record(2, true, true);
    }
    assert!(t.compute_path_etx(2, f32::INFINITY).is_infinite());
    assert!(t.compute_path_etx(2, f32::NAN).is_infinite());
}

#[test]
fn learn_route_first_infinite_metric_is_currently_accepted() {
    // OBSERVED-BEHAVIOUR pin, not a spec: `is_feasible` returns `true` when no
    // prior route exists (see routing.rs `is_feasible` match arm `None => true`),
    // so the very first `learn_route` call accepts a +inf metric. This is almost
    // certainly not what we want long-term — routing on +inf is meaningless and
    // will be immediately shadowed by any finite advertisement — but flipping
    // the check to also reject `!path_etx.is_finite()` on the None arm is a
    // real behaviour change that belongs in its own PR (post image-bake, when a
    // 3-node mesh can validate it). Pin the current behaviour so the future
    // fix is a loud, intentional diff. `-sim`.
    let mut t = EtxTable::new(10);
    assert!(t.learn_route(100, 2, f32::INFINITY));
    assert!(t.path_route(100).is_some());
    // But any finite metric is strictly better and instantly wins.
    assert!(t.learn_route(100, 3, 5.0));
    assert_eq!(t.path_route(100).map(|r| r.next_hop), Some(3));
}

#[test]
fn force_dead_on_unknown_neighbor_is_noop() {
    // Fast-fail must be idempotent on unknown neighbors — no panic, no state
    // corruption. This mirrors the real handler where a stale ID may fire.
    let mut t = EtxTable::new(10);
    t.force_dead(99);
    assert_eq!(t.etx(99), None);
}

#[test]
fn path_route_replaces_next_hop_when_strictly_better() {
    // Feasibility strictly requires a lower path_etx — verify next_hop swaps
    // together with the metric so the routing table stays coherent.
    let mut t = EtxTable::new(10);
    assert!(t.learn_route(50, 2, 10.0));
    assert!(t.learn_route(50, 7, 3.0));
    let r = t.path_route(50).unwrap();
    assert_eq!(r.next_hop, 7);
    assert!((r.path_etx - 3.0).abs() < 1e-6);
}

#[test]
fn neighbors_returned_sorted_by_id() {
    // The status view relies on stable ordering. Record neighbors out of order
    // and expect a sorted return.
    let mut t = EtxTable::new(10);
    for _ in 0..20 {
        t.record(9, true, true);
        t.record(3, true, true);
        t.record(5, true, true);
    }
    let ids: Vec<NodeId> = t.neighbors().into_iter().map(|(id, _)| id).collect();
    assert_eq!(ids, vec![3, 5, 9]);
}

// ---------------------------------------------------------------------------
// Cross-module invariant: no HELLO body ever collides with a mesh Header.
// Both wire formats coexist in the same UDP flow post-image-bake, so we pin
// the fact that their fixed-prefix bytes cannot be confused.
// ---------------------------------------------------------------------------

#[test]
fn header_and_hello_have_distinct_shapes() {
    // A well-formed Header is exactly 11 bytes starting with VERSION=1.
    // A well-formed Hello is at least 33 bytes with src:4 up front — it has no
    // fixed version byte. This test does not enforce disambiguation logic (the
    // outer transport is responsible), but it pins the size floor: any Hello
    // is strictly longer than the Header::LEN prefix.
    let h = Header::new(FrameKind::Hello, 1, 2, 3).to_bytes();
    let hello = Hello::new(1, 1, 1, vec![], [0u8; 16]).to_bytes();
    assert_eq!(h.len(), 11);
    assert!(hello.len() >= 33);
    assert!(hello.len() > h.len());
}
