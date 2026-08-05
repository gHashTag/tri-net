//! trinet_compute_over_mesh -- the signed compute receipt actually crosses the mesh.
//!
//! Every other proof runs the verify chain in-process. This one seals a real datagram:
//! the executor's Ed25519-signed receipt is framed (tri_a2a_wire), sealed with real
//! ChaCha20-Poly1305 under a crypto_frame nonce (crypto_frame.nonce_byte + a 12-byte
//! epoch||counter header as AEAD-authenticated associated data), forwarded by a BLIND
//! relay (no key -> ciphertext only), then opened by the verifier, which recovers the
//! receipt byte-exact and runs the SAME settle gate (signature + recompute + freshness).
//! Negatives: a tampered frame fails to open; a replayed counter is rejected by the
//! crypto_frame replay window. Crypto primitives are the Rust crates (not spec logic);
//! the frame/nonce/replay/wire LAYOUT is generated from specs/*.t27.
#![allow(dead_code, unused)]

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};

#[path = "../../gen/rust/crypto_frame.rs"] mod cf;
#[path = "../../gen/rust/tri_a2a.rs"] mod a2a;
#[path = "../../gen/rust/tri_a2a_wire.rs"] mod wire;
#[path = "../../gen/rust/tri_sha256.rs"] mod sha;
#[path = "../../gen/rust/tri_compute_receipt.rs"] mod receipt;
#[path = "../../gen/rust/tri_compute_settle.rs"] mod settle;
#[path = "../../gen/rust/tri_gft_arith.rs"] mod gmul;
#[path = "../../gen/rust/tri_gft_ladder.rs"] mod lad;

/// The 12-byte AEAD nonce, byte-for-byte from the spec (dir || epoch-be || counter-be).
fn build_nonce(dir: u8, epoch: u32, ctr: u64) -> [u8; 12] {
    let mut n = [0u8; 12];
    let mut i = 0u32;
    while i < 12 {
        n[i as usize] = cf::nonce_byte(dir, epoch, ctr, i) as u8;
        i += 1;
    }
    n
}

/// The 12-byte frame header = epoch (big-endian) || counter (big-endian), used as AAD.
fn frame_header(epoch: u32, ctr: u64) -> [u8; 12] {
    let mut h = [0u8; 12];
    h[0..4].copy_from_slice(&epoch.to_be_bytes());
    h[4..12].copy_from_slice(&ctr.to_be_bytes());
    h
}

fn operand_hash256(op: u32, a_off: u32, a_mant: u32, b_off: u32, b_mant: u32) -> [u32; 8] {
    let w = |i: u32| wire::operand_pre(i, op, a_off, a_mant, b_off, b_mant);
    let mut h = [0u32; 8];
    let mut k = 0u32;
    while k < 8 { h[k as usize] = sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), k); k += 1; }
    h
}

fn input_digest(req: u32, dev: u32, exe: u32, task: u32, oh: &[u32; 8], out: u32, epoch: u32, prev: u32) -> [u32; 8] {
    let w = |i: u32| receipt::input_digest_pre(i, req, dev, exe, task, oh[0], oh[1], oh[2], oh[3], oh[4], oh[5], oh[6], oh[7], out, epoch, prev);
    let mut s1 = [0u32; 8];
    let mut k = 0u32;
    while k < 8 { s1[k as usize] = sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), k); k += 1; }
    let mut d = [0u32; 8];
    let mut j = 0u32;
    while j < 8 { d[j as usize] = sha::sha256_compress(s1[0], s1[1], s1[2], s1[3], s1[4], s1[5], s1[6], s1[7], w(16), w(17), w(18), w(19), w(20), w(21), w(22), w(23), w(24), w(25), w(26), w(27), w(28), w(29), w(30), w(31), j); j += 1; }
    d
}

fn digest_bytes(d: &[u32; 8]) -> [u8; 32] {
    let mut b = [0u8; 32];
    let mut i = 0usize;
    while i < 8 { b[i * 4..i * 4 + 4].copy_from_slice(&d[i].to_be_bytes()); i += 1; }
    b
}

fn main() {
    // Roles: an executor holds the signing key; a relay forwards blindly; the requester
    // (dst == me at the far end) verifies and settles. dir = 1 is the exec->req channel.
    let (dir, epoch, ctr) = (1u8, 1u32, 0x2001u64);
    let key = Key::from_slice(&[7u8; 32]); // real key = mesh AKE (W3b/B'); fixed here for a KAT
    let cipher = ChaCha20Poly1305::new(key);

    // --- Executor: GF-T16 mul phi^1*phi^1 = phi^2, operands (41,0)&(41,0) -> (42,0). ---
    let (task, dev, exe, gfop, out, ep) = (wire::task_id(0x00, 0x00, 0x20, 0x01), 0xC0FFEE01u32, 0xE0E0u32, 0x11u32, 0x4100u32, 1u32);
    let (a_off, a_mant, b_off, b_mant) = (41u32, 0u32, 41u32, 0u32);
    let oh = operand_hash256(gfop, a_off, a_mant, b_off, b_mant);
    let d = input_digest(task, dev, exe, gfop, &oh, out, ep, receipt::RECEIPT_GENESIS);
    let sk = SigningKey::from_bytes(&[7u8; 32]);
    let vk = sk.verifying_key();
    let sig = sk.sign(&digest_bytes(&d));

    // Frame the TASK_RESULT: [class, task, skill, out] as big-endian words + 64-byte sig.
    let skill = wire::skill_id(0xA6, 0x11); // GF-T16 mul
    let mut pt: Vec<u8> = Vec::new();
    for wv in [wire::MSG_TASK_RESULT, task, skill, out] { pt.extend_from_slice(&wv.to_be_bytes()); }
    pt.extend_from_slice(&sig.to_bytes());

    // Seal: ChaCha20-Poly1305 over the plaintext, header (epoch||ctr) as AAD.
    let hdr = frame_header(epoch, ctr);
    let nonce = build_nonce(dir, epoch, ctr);
    let ct = cipher.encrypt(Nonce::from_slice(&nonce), Payload { msg: &pt, aad: &hdr }).expect("seal");
    let mut frame: Vec<u8> = Vec::new();
    frame.extend_from_slice(&hdr);
    frame.extend_from_slice(&ct);
    assert!(cf::frame_len_ok(frame.len()), "frame length is within the crypto_frame bounds");
    let co = cf::ciphertext_offset();
    assert_eq!(co, cf::HEADER_LEN, "ciphertext starts right after the 12-byte header");

    // --- Blind relay: it holds no key, so it only sees ciphertext. The sealed body is
    //     not the plaintext, and A2A rides on the KIND/PORT demux, never the payload. ---
    assert_ne!(&frame[co..co + pt.len()], &pt[..], "relay sees ciphertext, not the receipt");
    assert!(a2a::is_a2a(1, a2a::A2A_PORT), "A2A demuxes by port, not by opening the frame");

    // --- Verifier (dst == me): open the frame and recover the receipt byte-exact. ---
    let hdr_rx = &frame[..co];
    let ct_rx = &frame[co..];
    let nonce_rx = build_nonce(dir, epoch, ctr); // same nonce derivation reproduces the key stream
    let pt_rx = cipher.decrypt(Nonce::from_slice(&nonce_rx), Payload { msg: ct_rx, aad: hdr_rx }).expect("open");
    assert_eq!(pt_rx, pt, "the signed receipt survives mesh transit byte-exact");

    // Parse the wire header and settle with the SAME gate the in-process node uses.
    let r_class = u32::from_be_bytes([pt_rx[0], pt_rx[1], pt_rx[2], pt_rx[3]]);
    let r_out = u32::from_be_bytes([pt_rx[12], pt_rx[13], pt_rx[14], pt_rx[15]]);
    assert!(wire::class_valid(r_class) && r_class == wire::MSG_TASK_RESULT, "a valid taskResult");
    let mut sigb = [0u8; 64];
    sigb.copy_from_slice(&pt_rx[16..80]);
    let r_sig = Signature::from_bytes(&sigb);

    // Signature: the verifier recomputes the 256-bit input digest from ITS known operands
    // and the received output, then checks the recovered signature over it.
    let oh_v = operand_hash256(gfop, a_off, a_mant, b_off, b_mant);
    let d_v = input_digest(task, dev, exe, gfop, &oh_v, r_out, ep, receipt::RECEIPT_GENESIS);
    let sig_ok = vk.verify(&digest_bytes(&d_v), &r_sig).is_ok();
    // Correctness: recompute the GF-T16 product under its rung geometry.
    let e16 = lad::GFT16_ET;
    let cok = gmul::verify_gft_mul_full_p(a_off, a_mant, b_off, b_mant, 42, 0, lad::gft_bias(e16), lad::gft_offset_max(e16), lad::gft_mant_one(e16));
    // Freshness: first sight of this counter -> the replay window accepts it.
    let fresh = cf::replay_accept(false, 0, 0, 0, ctr);
    let gate = (sig_ok as u32) & (cok as u32) & (fresh as u32);
    let bal = settle::settle_signed(1000, 16, 1, r_out, 6, 9, 0, gate);
    assert_eq!((sig_ok, cok, fresh), (true, true, true), "opened receipt verifies");
    assert_eq!(bal, 1016, "signed + correct + fresh receipt settles after crossing the mesh");

    // --- NEGATIVE 1: a tampered frame does not open (AEAD integrity). ---
    let mut bad = frame.clone();
    bad[co + 5] ^= 0x01;
    let opened_bad = cipher.decrypt(Nonce::from_slice(&nonce_rx), Payload { msg: &bad[co..], aad: &bad[..co] });
    assert!(opened_bad.is_err(), "a tampered ciphertext fails to open -- no forged receipt reaches settle");

    // --- NEGATIVE 2: a replayed frame (same counter, already seen) is rejected. ---
    let top = cf::replay_next_top(false, 0, ctr);
    let blo = cf::replay_next_blo(false, 0, 0, 0, ctr);
    let bhi = cf::replay_next_bhi(false, 0, 0, 0, ctr);
    assert!(!cf::replay_accept(true, top, blo, bhi, ctr), "a replayed counter is rejected -> no double settle");

    println!("compute receipt over the sealed mesh (real ChaCha20-Poly1305 + crypto_frame layout):");
    println!("  frame = {}-byte header || ciphertext || 16-byte tag, len {} (frame_len_ok)", cf::HEADER_LEN, frame.len());
    println!("  relay: forwards ciphertext blindly (no key); A2A demux by port 0x{:03X}", a2a::A2A_PORT);
    println!("  verifier: opened byte-exact -> sig_ok={} recompute={} fresh={} -> settle 1000 -> {}", sig_ok, cok, fresh, bal);
    println!("  tampered frame -> open FAILS; replayed counter -> rejected");
    println!("OK: the signed compute receipt crosses a real sealed datagram and settles only when authentic, correct, and fresh");
}
