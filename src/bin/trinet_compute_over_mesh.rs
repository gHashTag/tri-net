//! trinet_compute_over_mesh -- a full A2A exchange crosses the mesh, both directions.
//!
//! Every other proof runs the verify chain in-process. This one seals real datagrams
//! for BOTH legs of the exchange:
//!   1. the requester seals a TASK_ASSIGN (op + the two GF-T operands, mantissa packed
//!      via tri_a2a_wire.assign_mant) and a BLIND relay forwards it (no key -> ciphertext);
//!   2. the executor OPENS it, computes on the operands it actually received, signs the
//!      256-bit input-bound receipt, and seals a TASK_RESULT back;
//!   3. the requester opens the result and settles with the same gate (signature +
//!      GF-T recompute + freshness) -- crucially recomputing the operand commitment from
//!      the operands IT SENT, so the input binding is proven end-to-end over the wire,
//!      not via shared local state.
//! Sealing is real ChaCha20-Poly1305 under a crypto_frame nonce (nonce_byte) with the
//! 12-byte epoch||counter header as AEAD associated data. Negatives: a tampered assign
//! or result fails to open; a replayed counter is rejected by the crypto_frame window.
//! Crypto primitives are Rust crates (not spec logic); frame/nonce/replay/wire LAYOUT is
//! generated from crypto_frame.t27 / tri_a2a_wire.t27 / tri_a2a.t27.
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
    while i < 12 { n[i as usize] = cf::nonce_byte(dir, epoch, ctr, i) as u8; i += 1; }
    n
}

/// The 12-byte frame header = epoch (big-endian) || counter (big-endian), used as AAD.
fn frame_header(epoch: u32, ctr: u64) -> [u8; 12] {
    let mut h = [0u8; 12];
    h[0..4].copy_from_slice(&epoch.to_be_bytes());
    h[4..12].copy_from_slice(&ctr.to_be_bytes());
    h
}

/// Seal a datagram: header(epoch||ctr) as AAD, ChaCha20-Poly1305 over the plaintext.
fn seal(cipher: &ChaCha20Poly1305, dir: u8, epoch: u32, ctr: u64, pt: &[u8]) -> Vec<u8> {
    let hdr = frame_header(epoch, ctr);
    let nonce = build_nonce(dir, epoch, ctr);
    let ct = cipher.encrypt(Nonce::from_slice(&nonce), Payload { msg: pt, aad: &hdr }).expect("seal");
    let mut f: Vec<u8> = Vec::new();
    f.extend_from_slice(&hdr);
    f.extend_from_slice(&ct);
    f
}

/// Open a datagram for the given channel direction; rebuilds the nonce from the header.
fn open(cipher: &ChaCha20Poly1305, dir: u8, frame: &[u8]) -> Result<Vec<u8>, ()> {
    let co = cf::ciphertext_offset();
    let hdr = &frame[..co];
    let ct = &frame[co..];
    let epoch = u32::from_be_bytes([hdr[0], hdr[1], hdr[2], hdr[3]]);
    let mut cb = [0u8; 8];
    cb.copy_from_slice(&hdr[4..12]);
    let ctr = u64::from_be_bytes(cb);
    let nonce = build_nonce(dir, epoch, ctr);
    cipher.decrypt(Nonce::from_slice(&nonce), Payload { msg: ct, aad: hdr }).map_err(|_| ())
}

fn push_word(v: &mut Vec<u8>, w: u32) { v.extend_from_slice(&w.to_be_bytes()); }
fn read_word(b: &[u8], word_idx: usize) -> u32 {
    let o = word_idx * 4;
    u32::from_be_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
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
    // Two channels of one AKE session (real keys = mesh handshake, W3b/B'; fixed for a KAT).
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&[7u8; 32]));
    let (dir_assign, dir_result, epoch) = (0u8, 1u8, 1u32); // req->exec=0, exec->req=1
    let (task, dev, exe, gfop, out, ep) = (wire::task_id(0x00, 0x00, 0x20, 0x01), 0xC0FFEE01u32, 0xE0E0u32, 0x11u32, 0x4100u32, 1u32);
    let skill = wire::skill_id(0xA6, 0x11); // GF-T16 mul

    // ===== LEG 1: requester seals a TASK_ASSIGN. GF-T16 1.5*1.5: operands (41,256).
    // The 9-bit mantissa 256 packs as hi=1, lo=0 (assign_mant(1,0) = 256). =====
    let (a_off, a_mant, b_off, b_mant) = (41u32, 256u32, 41u32, 256u32);
    let (a_hi, a_lo, b_hi, b_lo) = (1u32, 0u32, 1u32, 0u32);
    let mut assign_pt: Vec<u8> = Vec::new();
    for hw in [wire::MSG_TASK_ASSIGN, task, skill] { push_word(&mut assign_pt, hw); }
    for bw in [gfop, a_off, a_hi, a_lo, b_off, b_hi, b_lo] { push_word(&mut assign_pt, bw); } // ASSIGN body
    let assign_ctr = 0x2001u64;
    let assign_frame = seal(&cipher, dir_assign, epoch, assign_ctr, &assign_pt);
    assert!(cf::frame_len_ok(assign_frame.len()), "assign frame within crypto_frame bounds");

    // Blind relay: it has no key -> ciphertext only; A2A demux by port, not by opening.
    let co = cf::ciphertext_offset();
    assert_ne!(&assign_frame[co..co + assign_pt.len()], &assign_pt[..], "relay sees ciphertext, not operands");
    assert!(a2a::is_a2a(1, a2a::A2A_PORT), "A2A demuxes by port, never by parsing the payload");

    // ===== LEG 2: executor OPENS the assign and computes on the operands it received. =====
    let asg = open(&cipher, dir_assign, &assign_frame).expect("executor opens the assign");
    assert_eq!(asg, assign_pt, "operands survive mesh transit byte-exact");
    let r_gfop = read_word(&asg, 3 + wire::OFF_ASSIGN_OP as usize);
    let ra_off = read_word(&asg, 3 + wire::OFF_ASSIGN_A_OFF as usize);
    let ra_mant = wire::assign_mant(read_word(&asg, 3 + wire::OFF_ASSIGN_A_MANT as usize), read_word(&asg, 3 + wire::OFF_ASSIGN_A_MANT as usize + 1));
    let rb_off = read_word(&asg, 3 + wire::OFF_ASSIGN_B_OFF as usize);
    let rb_mant = wire::assign_mant(read_word(&asg, 3 + wire::OFF_ASSIGN_B_MANT as usize), read_word(&asg, 3 + wire::OFF_ASSIGN_B_MANT as usize + 1));
    assert_eq!((r_gfop, ra_off, ra_mant, rb_off, rb_mant), (gfop, a_off, a_mant, b_off, b_mant), "executor reconstructs the exact assigned operands");

    // Executor recomputes GF-T16 1.5*1.5 -> (exp 43, mant 64) under the rung geometry,
    // commits THOSE operands into the 256-bit input digest, and signs it.
    let e16 = lad::GFT16_ET;
    let exec_ok = gmul::verify_gft_mul_full_p(ra_off, ra_mant, rb_off, rb_mant, 43, 64, lad::gft_bias(e16), lad::gft_offset_max(e16), lad::gft_mant_one(e16));
    assert!(exec_ok, "executor's own recompute of the received operands checks out");
    let oh_exec = operand_hash256(r_gfop, ra_off, ra_mant, rb_off, rb_mant);
    let d = input_digest(task, dev, exe, gfop, &oh_exec, out, ep, receipt::RECEIPT_GENESIS);
    let sk = SigningKey::from_bytes(&[7u8; 32]);
    let vk = sk.verifying_key();
    let sig = sk.sign(&digest_bytes(&d));

    // Executor seals a TASK_RESULT: [class, task, skill, out] words + 64-byte signature.
    let mut result_pt: Vec<u8> = Vec::new();
    for hw in [wire::MSG_TASK_RESULT, task, skill, out] { push_word(&mut result_pt, hw); }
    result_pt.extend_from_slice(&sig.to_bytes());
    let result_ctr = 0x2002u64;
    let result_frame = seal(&cipher, dir_result, epoch, result_ctr, &result_pt);
    assert!(cf::frame_len_ok(result_frame.len()), "result frame within bounds");

    // ===== LEG 3: requester opens the result and settles. It recomputes the operand
    // commitment from the operands IT SENT -- so the signature only verifies if the
    // executor committed the SAME operands (end-to-end input binding, over the wire). =====
    let res = open(&cipher, dir_result, &result_frame).expect("requester opens the result");
    assert_eq!(res, result_pt, "signed receipt survives mesh transit byte-exact");
    let r_class = read_word(&res, 0);
    let r_out = read_word(&res, 3);
    assert!(wire::class_valid(r_class) && r_class == wire::MSG_TASK_RESULT, "a valid taskResult");
    let mut sigb = [0u8; 64];
    sigb.copy_from_slice(&res[16..80]);
    let r_sig = Signature::from_bytes(&sigb);

    let oh_req = operand_hash256(gfop, a_off, a_mant, b_off, b_mant); // requester's OWN operands
    let d_req = input_digest(task, dev, exe, gfop, &oh_req, r_out, ep, receipt::RECEIPT_GENESIS);
    let sig_ok = vk.verify(&digest_bytes(&d_req), &r_sig).is_ok();
    let cok = gmul::verify_gft_mul_full_p(a_off, a_mant, b_off, b_mant, 43, 64, lad::gft_bias(e16), lad::gft_offset_max(e16), lad::gft_mant_one(e16));
    let fresh = cf::replay_accept(false, 0, 0, 0, result_ctr);
    let gate = (sig_ok as u32) & (cok as u32) & (fresh as u32);
    let bal = settle::settle_signed(1000, 16, 1, r_out, 6, 9, 0, gate);
    assert_eq!((sig_ok, cok, fresh), (true, true, true), "opened receipt verifies end-to-end");
    assert_eq!(bal, 1016, "signed + correct + fresh receipt settles after a full mesh round-trip");

    // NEGATIVE 1: a tampered assign does not open (operands cannot be silently altered).
    let mut bad_asg = assign_frame.clone();
    bad_asg[co + 3] ^= 0x01;
    assert!(open(&cipher, dir_assign, &bad_asg).is_err(), "tampered assign fails to open");
    // NEGATIVE 2: a tampered result does not open (no forged receipt reaches settle).
    let mut bad_res = result_frame.clone();
    bad_res[co + 5] ^= 0x01;
    assert!(open(&cipher, dir_result, &bad_res).is_err(), "tampered result fails to open");
    // NEGATIVE 3: a replayed result counter is rejected by the crypto_frame window.
    let top = cf::replay_next_top(false, 0, result_ctr);
    let blo = cf::replay_next_blo(false, 0, 0, 0, result_ctr);
    let bhi = cf::replay_next_bhi(false, 0, 0, 0, result_ctr);
    assert!(!cf::replay_accept(true, top, blo, bhi, result_ctr), "replayed result counter rejected -> no double settle");

    println!("full A2A compute exchange over the sealed mesh (real ChaCha20-Poly1305):");
    println!("  LEG1 assign  ctr {:#x}: operands (41,256)*(41,256) sealed, len {} (blind relay)", assign_ctr, assign_frame.len());
    println!("  LEG2 executor opened byte-exact -> recompute (43,64)={} -> signed receipt", exec_ok);
    println!("  LEG3 result  ctr {:#x}: opened -> sig_ok={} recompute={} fresh={} -> settle 1000 -> {}", result_ctr, sig_ok, cok, fresh, bal);
    println!("  tampered assign & result -> open FAILS; replayed counter -> rejected");
    println!("OK: operands and receipt both cross real sealed datagrams; input binding holds end-to-end over the wire");
}
