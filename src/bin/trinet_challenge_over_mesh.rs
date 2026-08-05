//! trinet_challenge_over_mesh -- optimistic fraud-proof across the sealed mesh.
//!
//! An executor posts a bond and delivers a sealed CLAIM (operands + a claimed GF-T result
//! + the bond, signed) that is credited PROVISIONALLY. A challenger opens the sealed claim
//! and -- without trusting it -- INDEPENDENTLY recomputes the GF-T result from the operands
//! (tri_gft_arith.gft_mul_result). tri_compute_challenge.resolve compares claimed vs
//! recomputed: a mismatch is fraud -> the optimistic credit is REVERSED, the bond is
//! slashed, the challenger is rewarded (tri_compute_optimistic + tri_compute_bond). An
//! honest claim survives (PENDING, kept). So the fraud proof itself travels the wire: the
//! challenger's power is recomputation, not trust. Crypto = Rust crates; the frame / wire /
//! identity / optimistic / challenge / bond LAYOUT is generated from specs/*.t27.
#![allow(dead_code, unused)]

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};

#[path = "../../gen/rust/crypto_frame.rs"] mod cf;
#[path = "../../gen/rust/tri_a2a.rs"] mod a2a;
#[path = "../../gen/rust/tri_a2a_wire.rs"] mod wire;
#[path = "../../gen/rust/tri_sha256.rs"] mod sha;
#[path = "../../gen/rust/tri_node_identity.rs"] mod ident;
#[path = "../../gen/rust/tri_compute_receipt.rs"] mod receipt;
#[path = "../../gen/rust/tri_gft_arith.rs"] mod gfa;
#[path = "../../gen/rust/tri_compute_challenge.rs"] mod ch;
#[path = "../../gen/rust/tri_compute_bond.rs"] mod bond;
#[path = "../../gen/rust/tri_compute_optimistic.rs"] mod opt;

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
fn seal(cipher: &ChaCha20Poly1305, dir: u8, epoch: u32, ctr: u64, pt: &[u8]) -> Vec<u8> {
    let hdr = frame_header(epoch, ctr);
    let ct = cipher.encrypt(Nonce::from_slice(&build_nonce(dir, epoch, ctr)), Payload { msg: pt, aad: &hdr }).expect("seal");
    let mut f: Vec<u8> = Vec::new();
    f.extend_from_slice(&hdr);
    f.extend_from_slice(&ct);
    f
}
fn open(cipher: &ChaCha20Poly1305, dir: u8, frame: &[u8]) -> Result<Vec<u8>, ()> {
    let co = cf::ciphertext_offset();
    let hdr = &frame[..co];
    let epoch = u32::from_be_bytes([hdr[0], hdr[1], hdr[2], hdr[3]]);
    let mut cb = [0u8; 8];
    cb.copy_from_slice(&hdr[4..12]);
    let ctr = u64::from_be_bytes(cb);
    cipher.decrypt(Nonce::from_slice(&build_nonce(dir, epoch, ctr)), Payload { msg: &frame[co..], aad: hdr }).map_err(|_| ())
}

fn digest_bytes(d: &[u32; 8]) -> [u8; 32] {
    let mut b = [0u8; 32];
    let mut i = 0usize;
    while i < 8 { b[i * 4..i * 4 + 4].copy_from_slice(&d[i].to_be_bytes()); i += 1; }
    b
}
fn executor_id(pubkey: &[u8; 32]) -> u32 {
    let mut k = [0u32; 8];
    let mut i = 0usize;
    while i < 8 { k[i] = u32::from_be_bytes([pubkey[i * 4], pubkey[i * 4 + 1], pubkey[i * 4 + 2], pubkey[i * 4 + 3]]); i += 1; }
    let w = |j: u32| ident::pubkey_pre(j, k[0], k[1], k[2], k[3], k[4], k[5], k[6], k[7]);
    sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), 0)
}
fn operand_hash256(op: u32, a_off: u32, a_mant: u32, b_off: u32, b_mant: u32) -> [u32; 8] {
    let w = |i: u32| wire::operand_pre(i, op, a_off, a_mant, b_off, b_mant);
    let mut h = [0u32; 8];
    let mut k = 0u32;
    while k < 8 { h[k as usize] = sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), k); k += 1; }
    h
}
fn claim_digest(task: u32, dev: u32, exe: u32, gfop: u32, oh: &[u32; 8], claimed: u32, ep: u32) -> [u32; 8] {
    let w = |i: u32| receipt::input_digest_pre(i, task, dev, exe, gfop, oh[0], oh[1], oh[2], oh[3], oh[4], oh[5], oh[6], oh[7], claimed, ep, receipt::RECEIPT_GENESIS);
    let mut s1 = [0u32; 8];
    let mut k = 0u32;
    while k < 8 { s1[k as usize] = sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), k); k += 1; }
    let mut d = [0u32; 8];
    let mut j = 0u32;
    while j < 8 { d[j as usize] = sha::sha256_compress(s1[0], s1[1], s1[2], s1[3], s1[4], s1[5], s1[6], s1[7], w(16), w(17), w(18), w(19), w(20), w(21), w(22), w(23), w(24), w(25), w(26), w(27), w(28), w(29), w(30), w(31), j); j += 1; }
    d
}
fn read_u32(b: &[u8], off: usize) -> u32 { u32::from_be_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]]) }

// Claim byte layout.
const C_PUBKEY: usize = 0;
const C_EXEC: usize = 32;
const C_AOFF: usize = 36;
const C_AMANT: usize = 40;
const C_BOFF: usize = 44;
const C_BMANT: usize = 48;
const C_CLAIMED: usize = 52;
const C_BOND: usize = 56;
const C_SIG: usize = 60;
const C_LEN: usize = 124;

/// Executor seals a bonded claim: operands + a claimed result + bond, signed over the claim.
fn seal_claim(cipher: &ChaCha20Poly1305, ctr: u64, sk: &SigningKey, pubkey: &[u8; 32], exec_id: u32,
              task: u32, dev: u32, exe: u32, gfop: u32, a_off: u32, a_mant: u32, b_off: u32, b_mant: u32,
              claimed: u32, bond_amt: u32, ep: u32) -> Vec<u8> {
    let oh = operand_hash256(gfop, a_off, a_mant, b_off, b_mant);
    let d = claim_digest(task, dev, exe, gfop, &oh, claimed, ep);
    let sig = sk.sign(&digest_bytes(&d));
    let mut pt: Vec<u8> = Vec::new();
    pt.extend_from_slice(pubkey);
    pt.extend_from_slice(&exec_id.to_be_bytes());
    for wv in [a_off, a_mant, b_off, b_mant, claimed, bond_amt] { pt.extend_from_slice(&wv.to_be_bytes()); }
    pt.extend_from_slice(&sig.to_bytes());
    assert_eq!(pt.len(), C_LEN);
    seal(cipher, 1u8, 1u32, ctr, &pt)
}

fn main() {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&[7u8; 32]));
    let (task, dev, exe, gfop, ep) = (wire::task_id(0x00, 0x00, 0x50, 0x00), 0xC0FFEE01u32, 0xE0E0u32, 0x11u32, 1u32);
    let sk = SigningKey::from_bytes(&[7u8; 32]);
    let vk = sk.verifying_key();
    let pubkey = vk.to_bytes();
    let exec_id = executor_id(&pubkey);

    // GF-T16 mul phi^1*phi^1 -> encode(42,0). The FRAUD claim lies with encode(43,0).
    let (a_off, a_mant, b_off, b_mant) = (41u32, 0u32, 41u32, 0u32);
    let true_result = gfa::gft_mul_result(a_off, a_mant, b_off, b_mant, gfa::GFT16_BIAS, gfa::GFT16_OFFSET_MAX); // encode(42,0)
    let fraud_result = gfa::gft_result_encode(43, 0);
    let (reward, bond_amt, ex_bal0) = (16u32, 100u32, 500u32);
    assert!(bond::can_post(ex_bal0, bond_amt), "executor can post the bond");
    let bal_prov = opt::provisional_balance(1000, reward, 1); // 1016, provisionally credited
    let (settled_at, window, now) = (3u32, 10u32, 5u32); // now within [3, 13)

    // A challenger opens a sealed claim, verifies WHO, INDEPENDENTLY recomputes, resolves.
    let adjudicate = |ctr: u64, claimed: u32| -> (u32, u32, u32, u32) {
        let frame = seal_claim(&cipher, ctr, &sk, &pubkey, exec_id, task, dev, exe, gfop, a_off, a_mant, b_off, b_mant, claimed, bond_amt, ep);
        assert!(cf::frame_len_ok(frame.len()));
        // blind relay
        let co = cf::ciphertext_offset();
        assert!(a2a::is_a2a(1, a2a::A2A_PORT));
        let res = open(&cipher, 1u8, &frame).expect("challenger opens the claim");
        // parse
        let mut pk = [0u8; 32];
        pk.copy_from_slice(&res[C_PUBKEY..C_PUBKEY + 32]);
        let claimed_exec = read_u32(&res, C_EXEC);
        let (ra, rma, rb, rmb) = (read_u32(&res, C_AOFF), read_u32(&res, C_AMANT), read_u32(&res, C_BOFF), read_u32(&res, C_BMANT));
        let claimed_rx = read_u32(&res, C_CLAIMED);
        let bond_rx = read_u32(&res, C_BOND);
        let mut sb = [0u8; 64];
        sb.copy_from_slice(&res[C_SIG..C_SIG + 64]);
        // WHO: the claim is authentically the executor's (sig over the claim digest + id bind).
        let oh = operand_hash256(gfop, ra, rma, rb, rmb);
        let d = claim_digest(task, dev, exe, gfop, &oh, claimed_rx, ep);
        let sig_ok = VerifyingKey::from_bytes(&pk).unwrap().verify(&digest_bytes(&d), &Signature::from_bytes(&sb)).is_ok();
        let who = ident::who_ok(sig_ok as u32, claimed_exec, executor_id(&pk));
        assert!(who, "the claim is authenticated to the bonded executor");
        // Independent recompute -> resolve.
        let recomputed = gfa::gft_mul_result(ra, rma, rb, rmb, gfa::GFT16_BIAS, gfa::GFT16_OFFSET_MAX);
        let outcome = ch::resolve(claimed_rx, recomputed);
        let slashed = if outcome == ch::RESOLVE_SLASH { 1u32 } else { 0 };
        let w_open = if opt::window_open(now, settled_at, window) { 1u32 } else { 0 };
        let state = opt::settle_state(w_open, slashed);
        let bal = opt::balance_after_settle(bal_prov, reward, state);
        let ex_bond_after = ch::executor_bond_after(bond_rx, outcome);
        let ch_reward = ch::challenger_reward(bond_rx, outcome);
        (state, bal, ex_bond_after, ch_reward)
    };

    // Case FRAUD: the executor's sealed claim lies -> challenger recomputes -> SLASH/REVERSED.
    let (state_f, bal_f, bond_f, reward_f) = adjudicate(0x5001, fraud_result);
    assert_eq!(state_f, opt::REVERSED, "fraud is reversed");
    assert_eq!((bal_f, bond_f, reward_f), (1000, 0, bond_amt), "credit clawed back, bond slashed, challenger paid");

    // Case HONEST: the executor's sealed claim is correct -> challenge fails -> kept (PENDING).
    let (state_h, bal_h, bond_h, reward_h) = adjudicate(0x5002, true_result);
    assert_eq!(state_h, opt::PENDING, "an honest claim survives the challenge window");
    assert_eq!((bal_h, bond_h, reward_h), (1016, bond_amt, 0), "credit kept, bond intact, no challenger reward");

    println!("optimistic fraud-proof across the sealed mesh (challenger recomputes, does not trust):");
    println!("  provisional credit 1000 + {} = {} (bond {} posted)", reward, bal_prov, bond_amt);
    println!("  sealed FRAUD claim  encode(43,0) -> recompute encode(42,0) -> SLASH -> REVERSED bal {} (bond {}->{}, challenger +{})", bal_f, bond_amt, bond_f, reward_f);
    println!("  sealed HONEST claim encode(42,0) -> recompute matches -> challenge fails -> PENDING bal {} (bond kept {})", bal_h, bond_h);
    println!("OK: the fraud proof is recomputation over a real sealed datagram -- a lying bonded executor is slashed, an honest one survives");
}
