//! trinet_ledger_over_mesh -- an auditable settled-balance history crosses the mesh.
//!
//! The batch path settles N receipts under one signature per round. Across ROUNDS, each
//! round's batch root advances a 256-bit audited ledger head that commits
//! {prev_head, root, balance_after, epoch} via a two-block SHA-256
//! (tri_compute_receipt.ledger_entry_pre + tri_sha256). The executor chains R rounds,
//! signs the FINAL head once (Ed25519), and seals a datagram carrying the published head,
//! its signature, the presenter's key, and each round's (root, balance, epoch). A blind
//! relay forwards ciphertext. The verifier opens it and RECOMPUTES the chain from genesis
//! using the received rounds: if its head equals the published head (and the signature
//! verifies under the WHO identity binding), the whole balance history is authentic.
//! Negatives: rewriting any past round's balance makes the recomputed head diverge (the
//! head is tamper-evident); a history signed by the wrong key fails WHO. Crypto = Rust
//! crates; frame/nonce/identity/ledger LAYOUT is generated from specs/*.t27.
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

/// 256-bit settled-ledger head = two-block SHA-256(prev_head || digest || balance || epoch).
fn ledger_head256(prev: &[u32; 8], dg: &[u32; 8], balance: u32, epoch: u32) -> [u32; 8] {
    let w = |i: u32| receipt::ledger_entry_pre(i, prev[0], prev[1], prev[2], prev[3], prev[4], prev[5], prev[6], prev[7], dg[0], dg[1], dg[2], dg[3], dg[4], dg[5], dg[6], dg[7], balance, epoch);
    let mut s1 = [0u32; 8];
    let mut k = 0u32;
    while k < 8 { s1[k as usize] = sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), k); k += 1; }
    let mut head = [0u32; 8];
    let mut j = 0u32;
    while j < 8 { head[j as usize] = sha::sha256_compress(s1[0], s1[1], s1[2], s1[3], s1[4], s1[5], s1[6], s1[7], w(16), w(17), w(18), w(19), w(20), w(21), w(22), w(23), w(24), w(25), w(26), w(27), w(28), w(29), w(30), w(31), j); j += 1; }
    head
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
fn executor_id(pubkey: &[u8; 32]) -> u32 {
    let mut k = [0u32; 8];
    let mut i = 0usize;
    while i < 8 { k[i] = u32::from_be_bytes([pubkey[i * 4], pubkey[i * 4 + 1], pubkey[i * 4 + 2], pubkey[i * 4 + 3]]); i += 1; }
    let w = |j: u32| ident::pubkey_pre(j, k[0], k[1], k[2], k[3], k[4], k[5], k[6], k[7]);
    sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), 0)
}

fn push_leaf(v: &mut Vec<u8>, l: &[u32; 8]) { v.extend_from_slice(&digest_bytes(l)); }
fn read_leaf(b: &[u8], off: usize) -> [u32; 8] {
    let mut l = [0u32; 8];
    let mut i = 0usize;
    while i < 8 { l[i] = u32::from_be_bytes([b[off + i * 4], b[off + i * 4 + 1], b[off + i * 4 + 2], b[off + i * 4 + 3]]); i += 1; }
    l
}
fn read_u32(b: &[u8], off: usize) -> u32 { u32::from_be_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]]) }

const R: usize = 3;
const ROUND_LEN: usize = 32 + 4 + 4; // root + balance + epoch
const OFF_PUBKEY: usize = 0;
const OFF_EXEC: usize = 32;
const OFF_HEAD: usize = 36;
const OFF_SIG: usize = 68;
const OFF_ROUNDS: usize = 132;

/// Recompute the ledger head chain from genesis using the rounds in a batch buffer.
fn recompute_chain(buf: &[u8]) -> [u32; 8] {
    let mut head = [receipt::LEDGER_GENESIS, 0, 0, 0, 0, 0, 0, 0];
    let mut r = 0usize;
    while r < R {
        let base = OFF_ROUNDS + r * ROUND_LEN;
        let root = read_leaf(buf, base);
        let balance = read_u32(buf, base + 32);
        let epoch = read_u32(buf, base + 36);
        head = ledger_head256(&head, &root, balance, epoch);
        r += 1;
    }
    head
}

fn main() {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&[7u8; 32]));
    let (dir_result, epoch_frame, ctr) = (1u8, 1u32, 0x4001u64);
    let (dev, exe, gfop, ep) = (0xC0FFEE01u32, 0xE0E0u32, 0x11u32, 1u32);
    let oh = { let w = |i: u32| wire::operand_pre(i, gfop, 41, 256, 41, 256); let mut h = [0u32; 8]; let mut k = 0u32; while k < 8 { h[k as usize] = sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), k); k += 1; } h };

    // ===== Executor chains R rounds. Each round settles a batch (root) and advances the
    // head, committing the running balance. balance_r = 1000 + (r+1)*16. =====
    let mut roots = [[0u32; 8]; R];
    let mut balances = [0u32; R];
    let mut epochs = [0u32; R];
    let mut head = [receipt::LEDGER_GENESIS, 0, 0, 0, 0, 0, 0, 0];
    let mut r = 0usize;
    while r < R {
        roots[r] = input_digest(0x3000 + r as u32, dev, exe, gfop, &oh, 0x4100 + r as u32, ep, receipt::RECEIPT_GENESIS);
        balances[r] = 1000 + ((r as u32) + 1) * 16;
        epochs[r] = 1 + r as u32;
        head = ledger_head256(&head, &roots[r], balances[r], epochs[r]);
        r += 1;
    }
    let published_head = head;

    // ONE Ed25519 signature over the FINAL head authorizes the whole audited history.
    let sk = SigningKey::from_bytes(&[7u8; 32]);
    let vk = sk.verifying_key();
    let pubkey = vk.to_bytes();
    let sig = sk.sign(&digest_bytes(&published_head));
    let my_exec_id = executor_id(&pubkey);

    // Seal the ledger datagram: pubkey, exec, head, sig, then R (root, balance, epoch).
    let mut pt: Vec<u8> = Vec::new();
    pt.extend_from_slice(&pubkey);
    pt.extend_from_slice(&my_exec_id.to_be_bytes());
    push_leaf(&mut pt, &published_head);
    pt.extend_from_slice(&sig.to_bytes());
    for r in 0..R { push_leaf(&mut pt, &roots[r]); pt.extend_from_slice(&balances[r].to_be_bytes()); pt.extend_from_slice(&epochs[r].to_be_bytes()); }
    assert_eq!(pt.len(), OFF_ROUNDS + R * ROUND_LEN, "ledger layout size");
    let frame = seal(&cipher, dir_result, epoch_frame, ctr, &pt);
    assert!(cf::frame_len_ok(frame.len()));

    // Blind relay + A2A port demux.
    let co = cf::ciphertext_offset();
    assert_ne!(&frame[co..co + pt.len()], &pt[..], "relay sees ciphertext, not the ledger");
    assert!(a2a::is_a2a(1, a2a::A2A_PORT));

    // ===== Verifier: open, RECOMPUTE the chain from genesis, and audit. =====
    let res = open(&cipher, dir_result, &frame).expect("verifier opens the ledger");
    assert_eq!(res, pt, "ledger survives mesh transit byte-exact");
    let mut pk = [0u8; 32];
    pk.copy_from_slice(&res[OFF_PUBKEY..OFF_PUBKEY + 32]);
    let claimed_exec = read_u32(&res, OFF_EXEC);
    let published_rx = read_leaf(&res, OFF_HEAD);
    let mut sigb = [0u8; 64];
    sigb.copy_from_slice(&res[OFF_SIG..OFF_SIG + 64]);

    // (1) The recomputed chain must equal the published head -- the history is consistent.
    let recomputed = recompute_chain(&res);
    assert_eq!(recomputed, published_rx, "recomputed ledger head matches the published head");
    // (2) WHO: one signature over the head, bound to the presenter's key.
    let vk_rx = VerifyingKey::from_bytes(&pk).expect("valid key");
    let sig_ok = vk_rx.verify(&digest_bytes(&recomputed), &Signature::from_bytes(&sigb)).is_ok();
    let who = ident::who_ok(sig_ok as u32, claimed_exec, executor_id(&pk));
    assert!(who, "the audited history carries a valid executor signature over its head");
    // (3) Balance audit: the head commits the settled balance; the final round's balance
    // is the running total, each round +16 over the previous.
    let final_balance = read_u32(&res, OFF_ROUNDS + (R - 1) * ROUND_LEN + 32);
    assert_eq!(final_balance, 1048, "final settled balance committed by the head");

    // NEGATIVE 1 (history rewrite): tamper round 1's balance in the received buffer. The
    // recomputed head diverges from the published head -> the rewrite is detected.
    let mut rewritten = res.clone();
    let b1_off = OFF_ROUNDS + 1 * ROUND_LEN + 32;
    rewritten[b1_off..b1_off + 4].copy_from_slice(&9999u32.to_be_bytes());
    let recomputed_bad = recompute_chain(&rewritten);
    assert_ne!(recomputed_bad, published_rx, "rewriting a past round's balance is caught by the head");

    // NEGATIVE 2 (wrong signer): a history signed by another key fails WHO.
    let wrong_sig = SigningKey::from_bytes(&[9u8; 32]).sign(&digest_bytes(&recomputed));
    let wrong_ok = vk_rx.verify(&digest_bytes(&recomputed), &wrong_sig).is_ok();
    assert!(!ident::who_ok(wrong_ok as u32, claimed_exec, executor_id(&pk)), "a ledger signed by another key fails WHO");

    println!("auditable ledger head across {} rounds over the sealed mesh:", R);
    println!("  head chained round0 -> round1 -> round2, signed once, frame len {} (blind relay)", frame.len());
    println!("  opened byte-exact -> recomputed head == published -> WHO={} -> final balance {}", who, final_balance);
    println!("  rewriting a past round's balance -> head diverges (detected); wrong signer -> WHO fails");
    println!("OK: the 256-bit ledger head is a tamper-evident commitment to the settled-balance history, over a real sealed datagram");
}
