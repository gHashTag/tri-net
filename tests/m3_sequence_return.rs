#[allow(dead_code, unused_variables, unused_parens, clippy::all)]
#[path = "../gen/rust/m3_multihop.rs"]
mod generated;

#[test]
fn every_unsigned_byte_is_returned_as_its_wide_value() {
    for byte in 0u8..=255 {
        assert_eq!(generated::iperf3_sequence(byte), u32::from(byte));
    }
}
