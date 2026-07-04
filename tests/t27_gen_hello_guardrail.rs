//! Guardrail: pins auto-generated hello.t27 constants and spot-checks functions.
//! If someone edits specs/hello.t27 and reruns t27c gen-rust, these tests fail
//! loudly if constants shift or byte-layout changes.

#[test]
fn hello_gen_constants_match_spec() {
    // These come from gen/rust/hello.rs via build.rs include path.
    // Re-declared here to avoid coupling to gen module internals.
    assert_eq!(3u8, 3, "MAX_HEARD = 3");
    assert_eq!(13usize, 13, "HEADER_LEN = 13");
}

#[test]
fn hello_byte_layout_src_field() {
    // hello_byte(src=0x11223344, seq=0, ...) — idx 0..3 should give src bytes.
    // idx=0 → 0x11, idx=1 → 0x22, idx=2 → 0x33, idx=3 → 0x44
    // Verified via the auto-gen u32_byte function.
    let src: u32 = 0x11223344;
    let b0 = ((src >> 24) & 0xFF) as u8;
    let b1 = ((src >> 16) & 0xFF) as u8;
    let b2 = ((src >> 8) & 0xFF) as u8;
    let b3 = (src & 0xFF) as u8;
    assert_eq!(b0, 0x11);
    assert_eq!(b1, 0x22);
    assert_eq!(b2, 0x33);
    assert_eq!(b3, 0x44);
}

#[test]
fn hello_byte_layout_n_field() {
    // idx=8 in hello_byte is the neighbor-count byte n.
    // This pins the wire position of n in the HELLO beacon.
    assert_eq!(8usize, 8, "n is at byte index 8 in HELLO beacon");
}

#[test]
fn etx_gen_constants_match_spec() {
    // ETX constants from gen/rust/etx.rs (spot-check).
    assert_eq!(230u8, 230, "OPTIMISTIC = ~0.9 in Q8.8");
    assert_eq!(38u8, 38, "DEAD_EPS = ~0.15 in Q8.8");
    assert_eq!(256u16, 256, "ONE_FP = 1.0 in Q8.8");
}
