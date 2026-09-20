//! trinet_batch_over_mesh -- N receipts, ONE signature, settled across the sealed mesh.
//!
//! The single-receipt path (trinet_compute_over_mesh) signs and settles one result. This
//! is the throughput story: an executor that finished N tasks commits the N receipt
//! digests under ONE 256-bit Merkle root (H(l||r) via tri_compute_receipt.merkle_pair_pre
//! + tri_sha256), signs the ROOT once (Ed25519), and seals a batch datagram carrying the
//! root, its signature, the presenter's key, and for each receipt an independent
//! (leaf, inclusion-proof) package. A blind relay forwards ciphertext. The verifier opens
//! it, checks the ONE signature over the root with the WHO identity binding
//! (tri_node_identity.who_ok), then settles each receipt whose O(log N) proof folds to the
//! signed root -- amortizing one signature over N settlements. Negatives: a receipt whose
//! leaf is not under the root fails inclusion (rejected while the rest settle); a batch
//! signed by the wrong key fails WHO (the whole batch is rejected). Crypto = Rust crates;
//! frame/nonce/wire/identity/merkle LAYOUT is generated from specs/*.t27.
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
#[path = "../../gen/rust/tri_compute_settle.rs"] mod settle;

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

/// H(l||r) as a 256-bit Merkle parent, bit-exact via merkle_pair_pre + tri_sha256.
fn pair256(l: &[u32; 8], r: &[u32; 8]) -> [u32; 8] {
    let w = |i: u32| receipt::merkle_pair_pre(i, l[0], l[1], l[2], l[3], l[4], l[5], l[6], l[7], r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]);
    let mut s1 = [0u32; 8];
    let mut k = 0u32;
    while k < 8 { s1[k as usize] = sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), k); k += 1; }
    let mut o = [0u32; 8];
    let mut j = 0u32;
    while j < 8 { o[j as usize] = sha::sha256_compress(s1[0], s1[1], s1[2], s1[3], s1[4], s1[5], s1[6], s1[7], w(16), w(17), w(18), w(19), w(20), w(21), w(22), w(23), w(24), w(25), w(26), w(27), w(28), w(29), w(30), w(31), j); j += 1; }
    o
}

fn verify_inclusion(leaf: &[u32; 8], proof: &[([u32; 8], bool)]) -> [u32; 8] {
    let mut cur = *leaf;
    for (sib, right) in proof {
        cur = if *right { pair256(&cur, sib) } else { pair256(sib, &cur) };
    }
    cur
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

fn push_leaf(v: &mut Vec<u8>, l: &[u32; 8]) { v.extend_from_slice(&digest_bytes(l)); }
fn read_leaf(b: &[u8], off: usize) -> [u32; 8] {
    let mut l = [0u32; 8];
    let mut i = 0usize;
    while i < 8 { l[i] = u32::from_be_bytes([b[off + i * 4], b[off + i * 4 + 1], b[off + i * 4 + 2], b[off + i * 4 + 3]]); i += 1; }
    l
}
/// Serialize a 2-step proof: (sib32, dir) x2 = 66 bytes.
fn push_proof(v: &mut Vec<u8>, proof: &[([u32; 8], bool)]) {
    for (sib, right) in proof {
        push_leaf(v, sib);
        v.push(if *right { 1 } else { 0 });
    }
}
fn read_proof(b: &[u8], off: usize) -> [([u32; 8], bool); 2] {
    [(read_leaf(b, off), b[off + 32] == 1), (read_leaf(b, off + 33), b[off + 65] == 1)]
}

const N: usize = 4;
const REC_LEN: usize = 32 + 66; // leaf + 2-step proof
const OFF_ROOT: usize = 8;
const OFF_PUBKEY: usize = 40;
const OFF_EXEC: usize = 72;
const OFF_SIG: usize = 76;
const OFF_RECS: usize = 140;

fn main() {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&[7u8; 32]));
    let (dir_result, epoch, batch_ctr) = (1u8, 1u32, 0x3001u64);
    let (task, dev, exe, gfop, ep) = (wire::task_id(0x00, 0x00, 0x30, 0x00), 0xC0FFEE01u32, 0xE0E0u32, 0x11u32, 1u32);

    // ===== Executor finishes N=4 tasks; each yields a 256-bit input-bound receipt digest.
    // Same operands, distinct output field per task -> distinct leaves. =====
    let oh = operand_hash256(gfop, 41, 256, 41, 256);
    let mut leaves = [[0u32; 8]; N];
    let mut i = 0usize;
    while i < N { leaves[i] = input_digest(task + i as u32, dev, exe, gfop, &oh, 0x4100 + i as u32, ep, receipt::RECEIPT_GENESIS); i += 1; }

    // Merkle tree over the 4 leaves: n01, n23, root.
    let n01 = pair256(&leaves[0], &leaves[1]);
    let n23 = pair256(&leaves[2], &leaves[3]);
    let root = pair256(&n01, &n23);
    // Independent inclusion proofs (executor-computed, fixed siblings).
    let proofs: [[([u32; 8], bool); 2]; N] = [
        [(leaves[1], true), (n23, true)],   // leaf0: l1 right, n23 right
        [(leaves[0], false), (n23, true)],  // leaf1: l0 left,  n23 right
        [(leaves[3], true), (n01, false)],  // leaf2: l3 right, n01 left
        [(leaves[2], false), (n01, false)], // leaf3: l2 left,  n01 left
    ];

    // ONE Ed25519 signature over the ROOT authorizes all four receipts.
    let sk = SigningKey::from_bytes(&[7u8; 32]);
    let vk = sk.verifying_key();
    let pubkey = vk.to_bytes();
    let sig = sk.sign(&digest_bytes(&root));
    let my_exec_id = executor_id(&pubkey);

    // Seal the batch datagram: class, N, root, pubkey, exec, sig, then N (leaf, proof).
    let mut pt: Vec<u8> = Vec::new();
    pt.extend_from_slice(&wire::MSG_TASK_RESULT.to_be_bytes());
    pt.extend_from_slice(&(N as u32).to_be_bytes());
    push_leaf(&mut pt, &root);
    pt.extend_from_slice(&pubkey);
    pt.extend_from_slice(&my_exec_id.to_be_bytes());
    pt.extend_from_slice(&sig.to_bytes());
    for r in 0..N { push_leaf(&mut pt, &leaves[r]); push_proof(&mut pt, &proofs[r]); }
    assert_eq!(pt.len(), OFF_RECS + N * REC_LEN, "batch layout size");
    let frame = seal(&cipher, dir_result, epoch, batch_ctr, &pt);
    assert!(cf::frame_len_ok(frame.len()));

    // Blind relay + A2A port demux.
    let co = cf::ciphertext_offset();
    assert_ne!(&frame[co..co + pt.len()], &pt[..], "relay sees ciphertext, not the batch");
    assert!(a2a::is_a2a(1, a2a::A2A_PORT));

    // ===== Verifier: open, check the ONE signature over the root + WHO, settle each
    // receipt whose inclusion proof folds to the signed root. =====
    let res = open(&cipher, dir_result, &frame).expect("verifier opens the batch");
    assert_eq!(res, pt, "batch survives mesh transit byte-exact");
    let n = u32::from_be_bytes([res[4], res[5], res[6], res[7]]) as usize;
    let root_rx = read_leaf(&res, OFF_ROOT);
    let mut pk = [0u8; 32];
    pk.copy_from_slice(&res[OFF_PUBKEY..OFF_PUBKEY + 32]);
    let claimed_exec = u32::from_be_bytes([res[OFF_EXEC], res[OFF_EXEC + 1], res[OFF_EXEC + 2], res[OFF_EXEC + 3]]);
    let mut sigb = [0u8; 64];
    sigb.copy_from_slice(&res[OFF_SIG..OFF_SIG + 64]);
    let vk_rx = VerifyingKey::from_bytes(&pk).expect("valid key");
    let sig_ok = vk_rx.verify(&digest_bytes(&root_rx), &Signature::from_bytes(&sigb)).is_ok();
    let who = ident::who_ok(sig_ok as u32, claimed_exec, executor_id(&pk));
    assert!(who, "one batch signature + WHO authorizes the batch");

    // Settle each receipt by its inclusion proof against the signed root.
    let mut bal = 1000u32;
    let mut settled = 0u32;
    for r in 0..n {
        let base = OFF_RECS + r * REC_LEN;
        let leaf = read_leaf(&res, base);
        let proof = read_proof(&res, base + 32);
        let included = verify_inclusion(&leaf, &proof) == root_rx;
        bal = settle::settle_signed(bal, 16, 1, 0x4100 + r as u32, 6, 9, 0, (who as u32) & (included as u32));
        if included { settled += 1; }
    }
    assert_eq!((settled, bal), (4, 1064), "one signature settles all four receipts (4 x 16)");

    // NEGATIVE 1: a receipt whose leaf is NOT under the root fails inclusion -> not settled,
    // while the others still settle (per-receipt granularity, one bad receipt is isolated).
    let forged_leaf = input_digest(0xDEAD, dev, exe, gfop, &oh, 0x9999, ep, receipt::RECEIPT_GENESIS);
    let forged_included = verify_inclusion(&forged_leaf, &proofs[1]) == root_rx;
    let bal_forged = settle::settle_signed(1000, 16, 1, 0x9999, 6, 9, 0, (who as u32) & (forged_included as u32));
    assert!(!forged_included && bal_forged == 1000, "a receipt not committed under the root settles nothing");

    // NEGATIVE 2: a batch signed by the WRONG key fails WHO -> the whole batch is rejected.
    let wrong_sig = SigningKey::from_bytes(&[9u8; 32]).sign(&digest_bytes(&root_rx));
    let wrong_ok = vk_rx.verify(&digest_bytes(&root_rx), &wrong_sig).is_ok();
    assert!(!ident::who_ok(wrong_ok as u32, claimed_exec, executor_id(&pk)), "a batch signed by another key fails WHO");

    println!("N-receipt batch settled over the sealed mesh (one signature, {} receipts):", N);
    println!("  root sealed+signed once, batch frame len {} (blind relay)", frame.len());
    println!("  opened byte-exact -> WHO={} over the root -> {} receipts settle by inclusion -> bal {}", who, settled, bal);
    println!("  a receipt not under the root -> inclusion FAILS -> settles nothing; wrong signer -> WHO fails -> batch rejected");
    println!("OK: one Ed25519 signature over a 256-bit Merkle root settles N receipts across a real sealed datagram");
}
