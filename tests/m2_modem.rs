//! M2 integration: a sealed mesh frame survives a round-trip through the modem
//! transport (RRC + timing + CFO recovery) and still decrypts. Mirrors
//! `tests/m1_crypto.rs` `linked()`, but the wire is the radio PHY, not a socket.

use num_complex::Complex32;
use trios_mesh::daemon::Transport;
use trios_mesh::{Handshake, ModemTransport, Node, NodeId};

/// Two nodes with a completed X25519 session in each direction.
fn linked(a_id: NodeId, b_id: NodeId) -> (Node, Node) {
    let a = Handshake::new();
    let b = Handshake::new();
    let (a_pub, b_pub) = (a.public, b.public);
    let mut na = Node::new(a_id, 16);
    let mut nb = Node::new(b_id, 16);
    na.add_session(b_id, a.complete(&b_pub, true));
    nb.add_session(a_id, b.complete(&a_pub, false));
    (na, nb)
}

#[test]
fn transport_carries_mesh_frame() {
    let (mut alice, mut bob) = linked(1, 2);
    // Payload kept < 220 B so the sealed frame stays under the 255-B modem cap.
    let payload = b"the quick brown fox jumps over the lazy mesh node";
    let frame = alice.seal_data(2, 8, payload).unwrap();

    let mut radio = ModemTransport::new();
    radio.send(&frame).unwrap();
    let recovered = radio.recv().unwrap();

    assert_eq!(
        recovered, frame,
        "modem must recover the sealed frame verbatim"
    );
    assert_eq!(bob.open_data(1, &recovered).unwrap(), payload);
}

#[test]
fn tampered_iq_fails_downstream_auth() {
    let (mut alice, mut bob) = linked(1, 2);
    let payload = b"integrity over radio";
    let frame = alice.seal_data(2, 8, payload).unwrap();

    let mut radio = ModemTransport::new();
    radio.send(&frame).unwrap();
    let mut recovered = radio.recv().unwrap();

    // Flip a payload bit in the recovered frame: the modem carried it, but the
    // AEAD tag — not the modem — is what rejects it.
    let last = recovered.len() - 1;
    recovered[last] ^= 0x01;
    assert!(bob.open_data(1, &recovered).is_err());
}

/// The modem transport also survives a genuinely impaired channel.
#[test]
fn transport_survives_impaired_channel() {
    let (mut alice, mut bob) = linked(1, 2);
    let payload = b"delay + cfo + awgn, end to end";
    let frame = alice.seal_data(2, 8, payload).unwrap();

    // Impair the shaped IQ directly (fractional delay + CFO + AWGN), then recover.
    let tx = trios_mesh::tx_shaped(&frame);
    let two_pi = std::f32::consts::TAU;
    let mut seed: u64 = 0xD0D0;
    let mut gauss = || {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let u1 = (((seed >> 40) as f32) / ((1u64 << 24) as f32)).max(1e-7);
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let u2 = ((seed >> 40) as f32) / ((1u64 << 24) as f32);
        (-2.0 * u1.ln()).sqrt() * (two_pi * u2).cos()
    };
    let rx: Vec<Complex32> = (0..tx.len())
        .map(|i| {
            // fractional delay mu = 0.4 via linear interpolation
            let s = i as f32 + 0.4;
            let j = s.floor() as usize;
            let f = s - j as f32;
            let a = tx.get(j).copied().unwrap_or(Complex32::new(0.0, 0.0));
            let b = tx.get(j + 1).copied().unwrap_or(Complex32::new(0.0, 0.0));
            let delayed = a.scale(1.0 - f) + b.scale(f);
            // CFO 0.01 cyc/sym + phase, then AWGN
            let rot = delayed * Complex32::from_polar(1.0, 0.7 + two_pi * 0.01 * i as f32 / 4.0);
            rot + Complex32::new(0.05 * gauss(), 0.05 * gauss())
        })
        .collect();

    let recovered =
        trios_mesh::rx_recover(&rx).expect("frame must sync through the impaired channel");
    assert_eq!(bob.open_data(1, &recovered).unwrap(), payload);
}
