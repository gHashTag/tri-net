#[allow(dead_code, unused_variables, unused_parens, clippy::all)]
#[path = "../gen/rust/mesh_protocol_stack.rs"]
mod generated;

fn expected_route(current: u32, destination: u32) -> u32 {
    match (current, destination) {
        (1 | 3, 2) | (1, 3) | (3, 1) => 2,
        (2, 1) => 1,
        (2, 3) => 3,
        _ => 0,
    }
}

#[test]
fn every_ttl_payload_and_route_preserves_all_other_packet_bits() {
    for ttl in 0u32..16 {
        for payload in 0u32..256 {
            for source in [0u32, 1, 255] {
                for destination in [0u32, 1, 2, 3, 255] {
                    for current in [0u32, 1, 2, 3, 255] {
                        // Reserved bits are nonzero, unlike build_packet output.
                        let packet = (source << 24)
                            | (destination << 16)
                            | (ttl << 12)
                            | (0xf << 8)
                            | payload;
                        let remaining = ttl.saturating_sub(1);
                        let expected_packet = (packet & !(0xf << 12)) | (remaining << 12);
                        let expired = ttl <= 1;
                        let hop = if expired {
                            0
                        } else {
                            expected_route(current, destination)
                        };
                        assert_eq!(
                            generated::forward_packet(packet, current),
                            (expected_packet, expired, hop),
                            "ttl={ttl} source={source} destination={destination} current={current}"
                        );
                        assert_eq!(generated::extract_payload(expected_packet), payload as u8);
                    }
                }
            }
        }
    }
}

#[test]
fn exhausted_packet_stays_exhausted_across_further_hops() {
    for ttl in 0u8..16 {
        let mut packet = generated::build_packet(1, 3, ttl, 255);
        for hop in 1u32..20 {
            let (next, expired, route) = generated::forward_packet(packet, 1);
            assert_eq!(
                generated::extract_ttl(next),
                u32::from(ttl).saturating_sub(hop) as u8
            );
            assert_eq!(expired, hop >= u32::from(ttl));
            if expired {
                assert_eq!(route, 0);
            }
            assert_eq!(next & !(0xf << 12), packet & !(0xf << 12));
            packet = next;
        }
    }
}
