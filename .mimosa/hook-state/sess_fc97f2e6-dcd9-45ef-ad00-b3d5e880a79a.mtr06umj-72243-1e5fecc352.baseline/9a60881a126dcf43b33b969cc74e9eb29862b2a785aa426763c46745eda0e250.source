//! trinet_heartbeat_over_mesh -- signed liveness beacons prune dead hosts from routing.
//!
//! Discovery says a host CAN serve; a heartbeat says it is ALIVE. A host emits signed
//! HEARTBEAT beacons (tri_a2a_wire.MSG_HEARTBEAT, carrying no receipt) sealed over the
//! mesh, each with a monotonic sequence. The requester accepts one as fresh liveness only
//! if WHO holds (signed by the host's key, executor_id matches) AND tri_a2a.is_fresh
//! advances the watermark -- so a replayed beacon does not refresh liveness and a forged
//! beacon (wrong signer) is ignored. Routing then requires BOTH capability
//! (can_serve_skill_op) AND liveness: a capable host whose last beacon is older than the
//! liveness window is pruned. Crypto = Rust crates; class/freshness/card LAYOUT from
//! tri_a2a*.t27 + crypto_frame.t27 + tri_node_identity.t27.
#![allow(dead_code, unused)]

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};

#[path = "../../gen/rust/crypto_frame.rs"] mod cf;
#[path = "../../gen/rust/tri_a2a.rs"] mod a2a;
#[path = "../../gen/rust/tri_a2a_wire.rs"] mod wire;
#[path = "../../gen/rust/tri_a2a_card.rs"] mod card;
#[path = "../../gen/rust/tri_sha256.rs"] mod sha;
#[path = "../../gen/rust/tri_node_identity.rs"] mod ident;

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
fn executor_id(pubkey: &[u8; 32]) -> u32 {
    let mut k = [0u32; 8];
    let mut i = 0usize;
    while i < 8 { k[i] = u32::from_be_bytes([pubkey[i * 4], pubkey[i * 4 + 1], pubkey[i * 4 + 2], pubkey[i * 4 + 3]]); i += 1; }
    let w = |j: u32| ident::pubkey_pre(j, k[0], k[1], k[2], k[3], k[4], k[5], k[6], k[7]);
    sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), 0)
}
/// The 32-byte signed beacon message: class || seq || exec_id || zero-pad.
fn beacon_msg(class: u32, seq: u32, exec_id: u32) -> [u8; 32] {
    let mut m = [0u8; 32];
    m[0..4].copy_from_slice(&class.to_be_bytes());
    m[4..8].copy_from_slice(&seq.to_be_bytes());
    m[8..12].copy_from_slice(&exec_id.to_be_bytes());
    m
}
fn read_u32(b: &[u8], off: usize) -> u32 { u32::from_be_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]]) }
fn skill(hi: u32, lo: u32) -> u32 { (hi << 8) | lo }

// Beacon byte layout: pubkey@0, exec@32, class@36, seq@40, sig@44..108.
const H_PUBKEY: usize = 0;
const H_EXEC: usize = 32;
const H_CLASS: usize = 36;
const H_SEQ: usize = 40;
const H_SIG: usize = 44;

fn seal_beacon(cipher: &ChaCha20Poly1305, ctr: u64, sk: &SigningKey, pubkey: &[u8; 32], exec_id: u32, seq: u32) -> Vec<u8> {
    let sig = sk.sign(&beacon_msg(wire::MSG_HEARTBEAT, seq, exec_id));
    let mut pt: Vec<u8> = Vec::new();
    pt.extend_from_slice(pubkey);
    pt.extend_from_slice(&exec_id.to_be_bytes());
    pt.extend_from_slice(&wire::MSG_HEARTBEAT.to_be_bytes());
    pt.extend_from_slice(&seq.to_be_bytes());
    pt.extend_from_slice(&sig.to_bytes());
    seal(cipher, 1u8, 1u32, ctr, &pt)
}

/// Requester's view of a host's last verified liveness. Returns the (accepted, new_watermark).
fn accept_beacon(cipher: &ChaCha20Poly1305, frame: &[u8], last_seq: u32, trusted_exec: u32) -> (bool, u32) {
    let res = open(cipher, 1u8, frame).expect("beacon opens");
    let mut pk = [0u8; 32];
    pk.copy_from_slice(&res[H_PUBKEY..H_PUBKEY + 32]);
    let claimed_exec = read_u32(&res, H_EXEC);
    let class = read_u32(&res, H_CLASS);
    let seq = read_u32(&res, H_SEQ);
    let mut sb = [0u8; 64];
    sb.copy_from_slice(&res[H_SIG..H_SIG + 64]);
    let sig_ok = VerifyingKey::from_bytes(&pk).unwrap().verify(&beacon_msg(class, seq, claimed_exec), &Signature::from_bytes(&sb)).is_ok();
    let who = ident::who_ok(sig_ok as u32, claimed_exec, executor_id(&pk));
    // Accept as fresh liveness only if it is a valid heartbeat from the TRUSTED host and strictly newer.
    let ok = who && wire::class_valid(class) && class == wire::MSG_HEARTBEAT && claimed_exec == trusted_exec && a2a::is_fresh(seq, last_seq);
    (ok, a2a::next_watermark(seq, last_seq))
}

/// A host is alive if its last verified beacon is within the liveness window of now.
fn alive(now: u32, last_seq: u32, window: u32) -> bool { now < last_seq + window }

fn main() {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&[7u8; 32]));
    let sk = SigningKey::from_bytes(&[7u8; 32]);
    let pubkey = sk.verifying_key().to_bytes();
    let host_exec = executor_id(&pubkey);
    let window = 5u32;

    // The host also advertises GF-T16 mul (discovery); routing needs capability AND liveness.
    let host_card = card::make_card_ops(card::family_bit(card::FMT_GFT), 8 | 16, card::op_bit(card::GF_OP_MUL));
    let gft16_mul = skill(card::HI_GFT16, card::GF_OP_MUL);
    assert!(card::can_serve_skill_op(host_card, gft16_mul), "host is capable of GF-T16 mul");

    let mut last = 0u32;

    // Beacon seq 100 -> fresh, WHO ok -> liveness advances to 100.
    let (ok1, wm1) = accept_beacon(&cipher, &seal_beacon(&cipher, 0x8001, &sk, &pubkey, host_exec, 100), last, host_exec);
    assert!(ok1 && wm1 == 100, "first beacon establishes liveness at 100");
    last = wm1;

    // Beacon seq 101 -> fresh -> liveness advances to 101.
    let (ok2, wm2) = accept_beacon(&cipher, &seal_beacon(&cipher, 0x8002, &sk, &pubkey, host_exec, 101), last, host_exec);
    assert!(ok2 && wm2 == 101, "newer beacon advances liveness to 101");
    last = wm2;

    // NEGATIVE replay: seq 101 again -> not fresh -> liveness NOT refreshed.
    let (ok_replay, wm_r) = accept_beacon(&cipher, &seal_beacon(&cipher, 0x8003, &sk, &pubkey, host_exec, 101), last, host_exec);
    assert!(!ok_replay && wm_r == 101, "a replayed beacon does not refresh liveness");

    // NEGATIVE forged: a beacon signed by another key -> WHO fails -> ignored.
    let wrong_sk = SigningKey::from_bytes(&[9u8; 32]);
    let mut forged: Vec<u8> = Vec::new();
    forged.extend_from_slice(&pubkey);
    forged.extend_from_slice(&host_exec.to_be_bytes());
    forged.extend_from_slice(&wire::MSG_HEARTBEAT.to_be_bytes());
    forged.extend_from_slice(&200u32.to_be_bytes());
    forged.extend_from_slice(&wrong_sk.sign(&beacon_msg(wire::MSG_HEARTBEAT, 200, host_exec)).to_bytes());
    let (ok_forged, _) = accept_beacon(&cipher, &seal(&cipher, 1u8, 1, 0x8004, &forged), last, host_exec);
    assert!(!ok_forged, "a beacon signed by the wrong key fails WHO -> a peer cannot fake another's liveness");

    // ROUTING with liveness: capable AND alive -> routed; capable but stale -> pruned.
    let now_fresh = 105u32; // 105 < 101 + 5 = 106 -> alive
    let routable_fresh = card::can_serve_skill_op(host_card, gft16_mul) && alive(now_fresh, last, window);
    assert!(routable_fresh, "a capable, live host is routable at now=105");

    let now_stale = 110u32; // 110 >= 106 -> dead
    let routable_stale = card::can_serve_skill_op(host_card, gft16_mul) && alive(now_stale, last, window);
    assert!(!routable_stale, "a capable but STALE host (no recent beacon) is pruned from routing at now=110");

    println!("signed liveness beacons + routing over the sealed mesh:");
    println!("  beacon 100 -> 101 accepted (WHO + monotonic freshness); liveness watermark {}", last);
    println!("  replayed 101 -> not fresh -> liveness NOT refreshed; forged (wrong signer) -> ignored");
    println!("  routing = capability AND liveness: now=105 (<{}+{}) -> routable; now=110 -> pruned", last, window);
    println!("OK: a host is routed only when it authentically advertised the skill AND is provably alive; replay/forgery cannot fake liveness");
}
