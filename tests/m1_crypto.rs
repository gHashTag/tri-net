//! M1 integration test: end-to-end handshake → sealed datagram → tamper/replay
//! rejection through the public `Node` API. This is the regression baseline that
//! must stay green on the host and, later, on the real Zynq Mini ARM node.

use trios_mesh::{Handshake, MeshError, Node};

fn linked() -> (Node, Node) {
    let a = Handshake::new();
    let b = Handshake::new();
    let (a_pub, b_pub) = (a.public, b.public);
    let mut alice = Node::new(1, 16);
    let mut bob = Node::new(2, 16);
    alice.add_session(2, a.complete(&b_pub, true));
    bob.add_session(1, b.complete(&a_pub, false));
    (alice, bob)
}

#[test]
fn m1_roundtrip_tamper_replay() {
    let (mut alice, mut bob) = linked();

    // authentic
    let frame = alice.seal_data(2, 8, b"hello over the radio").unwrap();
    assert_eq!(bob.open_data(1, &frame).unwrap(), b"hello over the radio");

    // reverse direction works too (independent nonce space)
    let back = bob.seal_data(1, 8, b"ack").unwrap();
    assert_eq!(alice.open_data(2, &back).unwrap(), b"ack");

    // tamper
    let mut bad = frame.clone();
    let n = bad.len() - 1;
    bad[n] ^= 0x80;
    assert_eq!(bob.open_data(1, &bad), Err(MeshError::Auth));

    // replay of the original authentic frame
    assert_eq!(bob.open_data(1, &frame), Err(MeshError::Replay));
}

#[test]
fn m1_distinct_sessions_are_isolated() {
    let (mut alice, _bob) = linked();
    let (_carol, mut dave) = linked();
    let frame = alice.seal_data(2, 8, b"not for dave").unwrap();
    // dave holds a different session key → must not open alice's frame.
    assert_eq!(dave.open_data(1, &frame), Err(MeshError::Auth));
}
