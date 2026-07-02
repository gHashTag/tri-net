//! M1 smoke harness — the demonstration that graduates the crypto core from
//! `-sim` to `hw` when run on the real Zynq Mini ARM-Linux node (tri-net#10).
//!
//! Two peers complete an X25519 handshake, then exchange a ChaCha20-Poly1305
//! sealed datagram through the [`Node`] framing, and we prove that tamper and
//! replay are both rejected. Run: `cargo run --bin smoke-m1` (or on-device).

use trios_mesh::{Handshake, MeshError, Node};

fn main() {
    // --- handshake -------------------------------------------------------
    let a = Handshake::new();
    let b = Handshake::new();
    let (a_pub, b_pub) = (a.public, b.public);

    let mut alice = Node::new(1, 16);
    let mut bob = Node::new(2, 16);
    alice.add_session(2, a.complete(&b_pub, true));
    bob.add_session(1, b.complete(&a_pub, false));
    println!("[M1] X25519 handshake complete: node 1 <-> node 2");

    // --- authentic datagram ---------------------------------------------
    let payload = b"the quick brown fox jumps over the lazy mesh";
    let frame = alice.seal_data(2, 8, payload).expect("session exists");
    let opened = bob.open_data(1, &frame).expect("authentic frame opens");
    assert_eq!(opened, payload);
    println!(
        "[M1] AEAD round-trip OK: {} bytes plaintext -> {} bytes on-wire (ChaCha20-Poly1305)",
        payload.len(),
        frame.len()
    );

    // --- tamper is rejected ---------------------------------------------
    let mut bad = frame.clone();
    let last = bad.len() - 1;
    bad[last] ^= 0x01;
    assert_eq!(bob.open_data(1, &bad), Err(MeshError::Auth));
    println!("[M1] tamper rejected: flipped tag bit -> Auth error");

    // --- replay is rejected ---------------------------------------------
    assert_eq!(bob.open_data(1, &frame), Err(MeshError::Replay));
    println!("[M1] replay rejected: re-delivered frame -> Replay error");

    println!("\n[M1] PASS (-sim). Re-run on the Zynq Mini ARM node to graduate to hw.");
}
