//! a2a_mesh_multipath -- a compute result delivered over MULTIPLE mesh paths is resilient
//! to path drops AND to a subset of paths being tampered. The mesh may route the same
//! signed A2A datagram along several disjoint paths; each path independently either delivers
//! (hops within TTL) or drops (a2a_over_mesh_integrity). Unlike a verifier quorum -- which
//! votes on possibly-different recomputed VALUES (tri_compute_challenge.verifier_quorum3) --
//! every path here carries the SAME executor-signed receipt, so there is no value ambiguity:
//! the destination accepts iff ANY delivered path's leaf matches the signed leaf. Therefore
//!   * a path dropping does not lose the result if another path delivers (delivery resilience),
//!   * a path tampering does not corrupt the result if an honest path delivers (the signature
//!     picks the honest leaf), and
//!   * if every delivering path is tampered (or all drop), nothing is accepted (fail closed).

const MAX_HOPS: u8 = 3;

/// A single path carries (ttl, hop_count, delivered_leaf). It DELIVERS iff hops <= ttl.
struct Path {
    ttl: u8,
    hops: u32,
    leaf: u32, // the leaf this path delivers (== signed leaf if honest, else tampered)
}

/// Multipath delivery: the destination accepts the signed leaf iff at least one path both
/// delivers (within its TTL) AND carries the signed leaf. Returns the accepted leaf or None.
fn multipath_accept(paths: &[Path], signed_leaf: u32) -> Option<u32> {
    for p in paths {
        if p.hops <= p.ttl as u32 && p.leaf == signed_leaf {
            return Some(signed_leaf);
        }
    }
    None
}

fn honest(ttl: u8, hops: u32, signed: u32) -> Path {
    Path {
        ttl,
        hops,
        leaf: signed,
    }
}
fn dropped(hops: u32, signed: u32) -> Path {
    Path {
        ttl: MAX_HOPS,
        hops,
        leaf: signed,
    } // hops > ttl => drops
}
fn tampered(ttl: u8, hops: u32, signed: u32) -> Path {
    Path {
        ttl,
        hops,
        leaf: signed ^ 0xDEAD_BEEF,
    }
}

#[test]
fn one_delivering_path_is_enough() {
    let signed = 0x1234_ABCD;
    // Path A drops (5 hops on ttl 3); path B delivers (2 hops). Result still arrives.
    let paths = [
        dropped(MAX_HOPS as u32 + 2, signed),
        honest(MAX_HOPS, 2, signed),
    ];
    assert_eq!(
        multipath_accept(&paths, signed),
        Some(signed),
        "a surviving path delivers the result"
    );
}

#[test]
fn all_paths_dropping_delivers_nothing() {
    let signed = 0x1234_ABCD;
    let paths = [dropped(4, signed), dropped(5, signed), dropped(9, signed)];
    assert_eq!(
        multipath_accept(&paths, signed),
        None,
        "if every path drops, nothing is accepted"
    );
}

#[test]
fn a_tampered_path_cannot_beat_an_honest_one() {
    let signed = 0x1234_ABCD;
    // A tampering relay delivers a rewritten leaf on one path; an honest path also delivers.
    let paths = [tampered(MAX_HOPS, 1, signed), honest(MAX_HOPS, 3, signed)];
    assert_eq!(
        multipath_accept(&paths, signed),
        Some(signed),
        "the honest path's signed leaf is accepted, tamper ignored"
    );
    // Order must not matter: the honest leaf wins even if the tampered path is checked last.
    let paths_rev = [honest(MAX_HOPS, 3, signed), tampered(MAX_HOPS, 1, signed)];
    assert_eq!(
        multipath_accept(&paths_rev, signed),
        Some(signed),
        "acceptance is by signature match, not arrival order"
    );
}

#[test]
fn every_delivering_path_tampered_is_rejected() {
    let signed = 0x1234_ABCD;
    // Both delivering paths are tampered; the only honest path drops. Nothing verifies.
    let paths = [
        tampered(MAX_HOPS, 1, signed),
        tampered(MAX_HOPS, 2, signed),
        dropped(9, signed),
    ];
    assert_eq!(
        multipath_accept(&paths, signed),
        None,
        "no signature-matching leaf -> fail closed"
    );
}
