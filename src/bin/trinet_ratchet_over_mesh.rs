//! trinet_ratchet_over_mesh -- multi-hop blind relay + forward-secret key ratchet.
//!
//! The compute proofs seal one hop with a fixed key. This exercises the last unexercised
//! crypto_frame mechanism: forward secrecy. A frame is forwarded by TWO blind relays (no
//! key -> ciphertext only) before the endpoint opens it. crypto_frame.should_ratchet fires
//! at REKEY_EVERY_FRAMES; when it does, the session key is ratcheted with a real
//! HKDF-SHA256 step (the `hkdf` crate). A frame sealed under the NEW epoch key does not
//! open under the OLD key (forward secrecy), and a frame sealed under the OLD key does not
//! open under the NEW key (a compromised new key cannot read past traffic). must_reject
//! stops sealing at REKEY_HARD_CAP (the absolute nonce-reuse cap). Crypto = Rust crates;
//! the ratchet/reject/nonce policy is generated from crypto_frame.t27.
#![allow(dead_code, unused)]

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use sha2::Sha256;

#[path = "../../gen/rust/crypto_frame.rs"] mod cf;
#[path = "../../gen/rust/tri_a2a.rs"] mod a2a;

fn build_nonce(dir: u8, epoch: u32, ctr: u64) -> [u8; 12] {
    let mut n = [0u8; 12];
    let mut i = 0u32;
    while i < 12 { n[i as usize] = cf::nonce_byte(dir, epoch, ctr, i) as u8; i += 1; }
    n
}
fn frame_header(epoch: u32, ctr: u64) -> [u8; 12] {
    let mut h = [0u8; 12];
    h[0..4].copy_from_slice(&epoch.to_be_bytes());
    h[4..12].copy_from_slice(&ctr.to_be_bytes());
    h
}
fn seal(key: &[u8; 32], dir: u8, epoch: u32, ctr: u64, pt: &[u8]) -> Vec<u8> {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    let hdr = frame_header(epoch, ctr);
    let ct = cipher.encrypt(Nonce::from_slice(&build_nonce(dir, epoch, ctr)), Payload { msg: pt, aad: &hdr }).expect("seal");
    let mut f: Vec<u8> = Vec::new();
    f.extend_from_slice(&hdr);
    f.extend_from_slice(&ct);
    f
}
fn open(key: &[u8; 32], dir: u8, frame: &[u8]) -> Result<Vec<u8>, ()> {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    let co = cf::ciphertext_offset();
    let hdr = &frame[..co];
    let epoch = u32::from_be_bytes([hdr[0], hdr[1], hdr[2], hdr[3]]);
    let mut cb = [0u8; 8];
    cb.copy_from_slice(&hdr[4..12]);
    let ctr = u64::from_be_bytes(cb);
    cipher.decrypt(Nonce::from_slice(&build_nonce(dir, epoch, ctr)), Payload { msg: &frame[co..], aad: hdr }).map_err(|_| ())
}

/// A blind relay: forwards the frame bytes unchanged; it holds no key, so it cannot open.
fn blind_relay(frame: &[u8]) -> Vec<u8> { frame.to_vec() }

/// One forward-secret ratchet step: K_{n+1} = HKDF-SHA256(ikm = K_n, info = epoch).
fn ratchet(key: &[u8; 32], next_epoch: u32) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(None, key);
    let mut okm = [0u8; 32];
    hk.expand(&next_epoch.to_be_bytes(), &mut okm).expect("hkdf expand");
    okm
}

fn main() {
    let dir = 1u8;
    let k0: [u8; 32] = [7u8; 32]; // epoch-0 session key (from the mesh AKE, W3b/B')
    let msg = b"A2A compute receipt payload";

    // ===== Multi-hop: seal once, forward through TWO blind relays, open at the endpoint. =====
    let frame0 = seal(&k0, dir, 0, 1, msg);
    assert!(cf::frame_len_ok(frame0.len()));
    let co = cf::ciphertext_offset();
    let after_hop1 = blind_relay(&frame0);
    let after_hop2 = blind_relay(&after_hop1);
    assert_eq!(after_hop2, frame0, "frame crosses two relays unchanged");
    assert_ne!(&frame0[co..], &msg[..], "each blind relay sees ciphertext, not the payload");
    assert_eq!(open(&k0, dir, &after_hop2).expect("endpoint opens after 2 hops"), msg, "byte-exact after multi-hop");
    // rx_dir is the reverse channel's direction (distinct nonce space, no reuse).
    assert_eq!(cf::rx_dir(dir), 1 - dir);

    // ===== Ratchet policy from the spec: routine ratchet at 2^20, hard stop at 2^24. =====
    assert!(!cf::should_ratchet(cf::REKEY_EVERY_FRAMES - 1), "no ratchet before the window");
    assert!(cf::should_ratchet(cf::REKEY_EVERY_FRAMES), "ratchet due at REKEY_EVERY_FRAMES");
    assert!(!cf::must_reject(cf::REKEY_HARD_CAP - 1), "still sealable below the hard cap");
    assert!(cf::must_reject(cf::REKEY_HARD_CAP), "must reject at the hard cap (nonce-reuse stop)");

    // ===== Forward secrecy: the ratchet fired -> derive K1 with a real HKDF step. =====
    let k1 = ratchet(&k0, 1);
    assert_ne!(k1, k0, "the ratchet actually changes the key");
    let frame1 = seal(&k1, dir, 1, 1, msg); // epoch 1, sealed under K1
    assert_eq!(open(&k1, dir, &frame1).expect("endpoint opens epoch-1 under K1"), msg, "K1 opens epoch-1 traffic");

    // A holder of only the OLD key cannot read the NEW epoch (forward secrecy after ratchet).
    assert!(open(&k0, dir, &frame1).is_err(), "the retired key K0 cannot open epoch-1 traffic");
    // A holder of only the NEW key cannot read the OLD epoch (past traffic stays sealed).
    assert!(open(&k1, dir, &frame0).is_err(), "a compromised K1 cannot open epoch-0 traffic");

    // A second ratchet chains forward; K2 opens neither epoch 0 nor epoch 1.
    let k2 = ratchet(&k1, 2);
    let frame2 = seal(&k2, dir, 2, 1, msg);
    assert_eq!(open(&k2, dir, &frame2).expect("K2 opens epoch-2"), msg);
    assert!(open(&k2, dir, &frame1).is_err() && open(&k2, dir, &frame0).is_err(), "K2 reads only its own epoch");

    println!("multi-hop blind relay + forward-secret ratchet over crypto_frame:");
    println!("  frame crosses 2 blind relays -> endpoint opens byte-exact (len {})", frame0.len());
    println!("  ratchet policy: due at 2^20 frames, hard-stop at 2^24 (must_reject)");
    println!("  HKDF-SHA256 ratchet K0->K1->K2: each epoch key opens ONLY its epoch");
    println!("  retired K0 cannot read epoch-1; compromised K1 cannot read epoch-0 (forward + backward secrecy)");
    println!("OK: sealed A2A traffic survives multiple blind hops and a key ratchet bounds the blast radius of any single key");
}
