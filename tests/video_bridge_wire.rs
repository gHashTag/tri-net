//! Executes what specs/video_bridge.t27 only CLAIMS.
//!
//! The spec declares 24 test/invariant blocks, but t27c's gen-rust emits none of
//! them: all 84 modules under gen/rust carry zero #[test]. Project-wide, 887
//! spec-level test/invariant blocks produce 0 runnable tests, so L4 TESTABILITY
//! is satisfied on paper while the mesh wire format is verified by nothing.
//!
//! This file runs the spec's claims against the generated code, plus the
//! fragmentation round-trip the phone->mesh path actually depends on. It is a
//! test, not business logic, so it does not violate the golden pipeline; delete
//! it the day t27c emits spec tests itself.

use trios_mesh::video_bridge as vb;

// ---- sequence packing (spec: frag_seq_roundtrip / _zero / _max, seq_lo/hi) ----

#[test]
fn seq_packs_and_unpacks_over_the_whole_u16_range() {
    // The spec asserts a round-trip only at 0 and max; check every value, since
    // seq wraps continuously during a call.
    for seq in 0u16..=u16::MAX {
        let lo = vb::seq_lo(seq);
        let hi = vb::seq_hi(seq);
        assert_eq!(vb::frag_seq(lo, hi), seq, "seq {seq} did not survive lo/hi split");
    }
}

#[test]
fn seq_edges_match_the_spec() {
    assert_eq!(vb::frag_seq(0, 0), 0);
    assert_eq!(vb::frag_seq(255, 255), 65535);
    assert_eq!(vb::seq_lo(0x1234), 0x34);
    assert_eq!(vb::seq_hi(0x1234), 0x12);
}

// ---- fragment counting (spec: fragment_count_exact/_remainder/_zero/_large) ----

#[test]
fn fragment_count_covers_every_nal_the_mesh_accepts() {
    assert_eq!(vb::fragment_count(0), 1, "an empty NAL must still be one packet");
    assert_eq!(vb::fragment_count(1), 1);
    assert_eq!(vb::fragment_count(70), 1, "exactly one full fragment");
    assert_eq!(vb::fragment_count(71), 2, "one byte over must spill into a second");
    assert_eq!(vb::fragment_count(140), 2);
    assert_eq!(vb::fragment_count(17850), 255, "255 x 70 is the ceiling");

    // The count must never disagree with a straight ceiling division, and must
    // never exceed the u8 frag_count field the wire header carries.
    for size in (0u16..=17850).step_by(7) {
        let expect = if size == 0 { 1 } else { (size as u32).div_ceil(70) as u8 };
        assert_eq!(vb::fragment_count(size), expect, "nal_size {size}");
    }
}

#[test]
fn nal_ceiling_is_exactly_what_the_header_can_address() {
    // frag_count is one byte and each fragment carries <=70B, so the largest
    // addressable NAL is 255*70. A phone I-frame above this is silently
    // undeliverable over the mesh — this is the number the encoder must respect.
    assert_eq!(vb::max_nal_size(), 255 * 70);
    assert!(vb::nal_fits(17850));
    assert!(!vb::nal_fits(17851), "one byte over the ceiling must be rejected");
}

// ---- packet geometry (spec: packet_size_basic/_empty, data_offset) ----

#[test]
fn packet_geometry_holds() {
    assert_eq!(vb::packet_size(0), 5, "header only");
    assert_eq!(vb::packet_size(70), 75, "header + a full fragment");
    assert_eq!(vb::data_offset(), vb::FRAG_HEADER_LEN);
    // The full packet must stay inside the modem's 255-byte frame (modem.rs
    // MAX_FRAME) once mesh header + counter + AEAD tag are added on top.
    assert!(vb::packet_size(vb::MAX_FRAG_DATA) < 255);
}

#[test]
fn first_and_last_fragment_predicates_agree_with_the_count() {
    assert!(vb::is_first_fragment(0));
    assert!(!vb::is_first_fragment(1));
    assert!(vb::is_last_fragment(0, 1), "a single-fragment NAL is immediately last");
    assert!(!vb::is_last_fragment(0, 2));
    assert!(vb::is_last_fragment(1, 2));
    // Exactly one index may be last, for every count the header can express.
    for count in 1u8..=255 {
        let lasts = (0..count).filter(|&i| vb::is_last_fragment(i, count)).count();
        assert_eq!(lasts, 1, "frag_count {count} must have exactly one last fragment");
    }
}

// ---- the round-trip the phone->mesh path actually depends on ----

// Mirrors the daemon's split: [type][seq_lo][seq_hi][idx][count][data<=70].
fn fragment(nal: &[u8], seq: u16) -> Vec<Vec<u8>> {
    let count = vb::fragment_count(nal.len() as u16);
    (0..count)
        .map(|idx| {
            let start = idx as usize * vb::MAX_FRAG_DATA as usize;
            let end = (start + vb::MAX_FRAG_DATA as usize).min(nal.len());
            let mut p = vec![
                vb::VSTREAM_TYPE,
                vb::seq_lo(seq),
                vb::seq_hi(seq),
                idx,
                count,
            ];
            p.extend_from_slice(&nal[start..end]);
            p
        })
        .collect()
}

fn reassemble(mut packets: Vec<Vec<u8>>) -> Option<Vec<u8>> {
    packets.sort_by_key(|p| p[vb::FRAG_INDEX_OFFSET as usize]);
    let count = packets.first()?[vb::FRAG_COUNT_OFFSET as usize];
    if packets.len() != count as usize {
        return None; // a hole: the NAL is undeliverable, not silently truncated
    }
    Some(
        packets
            .iter()
            .flat_map(|p| p[vb::data_offset() as usize..].to_vec())
            .collect(),
    )
}

#[test]
fn nal_survives_fragmentation_and_reassembly() {
    // Sizes that bracket the real traffic: SEI, P-frames, a fat I-frame, and the
    // exact ceiling. 3240 is a real I-frame observed on the wire.
    for &size in &[1usize, 35, 70, 71, 859, 2138, 3240, 17850] {
        let nal: Vec<u8> = (0..size).map(|i| (i * 31 % 251) as u8).collect();
        let packets = fragment(&nal, 0xBEEF);
        assert!(
            packets.iter().all(|p| p.len() <= 75),
            "size {size}: a packet exceeded header+70"
        );
        assert_eq!(
            reassemble(packets).as_deref(),
            Some(nal.as_slice()),
            "size {size} did not survive the round trip"
        );
    }
}

#[test]
fn out_of_order_fragments_still_reassemble() {
    // The mesh is a shared medium with per-hop queuing; arrival order is not
    // send order.
    let nal: Vec<u8> = (0..3240).map(|i| (i * 17 % 253) as u8).collect();
    let mut packets = fragment(&nal, 7);
    packets.reverse();
    assert_eq!(reassemble(packets).as_deref(), Some(nal.as_slice()));
}

#[test]
fn a_lost_fragment_is_reported_not_silently_truncated() {
    // Losing a fragment must fail loudly; a short NAL handed to the decoder is
    // how the phone app once got a PLI storm.
    let nal: Vec<u8> = (0..3240).map(|i| (i % 250) as u8).collect();
    let mut packets = fragment(&nal, 9);
    packets.remove(10);
    assert_eq!(reassemble(packets), None);
}
