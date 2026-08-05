//! trinet_discovery_over_mesh -- capability-advertised routing across the sealed mesh.
//!
//! Before any compute exchange, a requester must find a CAPABLE host. A host advertises a
//! signed capability CARD (tri_a2a_card.make_card_ops: the (family, width, op) sets it
//! serves), sealed and delivered over the mesh. The requester opens it, verifies WHO (the
//! card is authentically that host's), and routes a task ONLY if can_serve_skill_op(card,
//! skill) holds -- so a task is never assigned to a host that has not advertised the
//! family, width, AND op. Negatives: a skill whose family / width / op the host did not
//! advertise is NOT routed; a card signed by the wrong key fails WHO (a forged
//! advertisement is ignored). Crypto = Rust crates; the card/skill LAYOUT is generated
//! from tri_a2a_card.t27 + crypto_frame.t27 + tri_node_identity.t27.
#![allow(dead_code, unused)]

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};

#[path = "../../gen/rust/crypto_frame.rs"] mod cf;
#[path = "../../gen/rust/tri_a2a.rs"] mod a2a;
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
/// A 32-byte message committing the advertised card (card word || zero-pad).
fn card_msg(card_word: u32) -> [u8; 32] {
    let mut m = [0u8; 32];
    m[0..4].copy_from_slice(&card_word.to_be_bytes());
    m
}
fn read_u32(b: &[u8], off: usize) -> u32 { u32::from_be_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]]) }
fn skill(hi: u32, lo: u32) -> u32 { (hi << 8) | lo }

// Card frame byte layout: pubkey@0, exec@32, card@36, sig@40..104.
const D_PUBKEY: usize = 0;
const D_EXEC: usize = 32;
const D_CARD: usize = 36;
const D_SIG: usize = 40;

/// Host seals a signed capability card.
fn seal_card(cipher: &ChaCha20Poly1305, ctr: u64, sk: &SigningKey, pubkey: &[u8; 32], exec_id: u32, card_word: u32) -> Vec<u8> {
    let sig = sk.sign(&card_msg(card_word));
    let mut pt: Vec<u8> = Vec::new();
    pt.extend_from_slice(pubkey);
    pt.extend_from_slice(&exec_id.to_be_bytes());
    pt.extend_from_slice(&card_word.to_be_bytes());
    pt.extend_from_slice(&sig.to_bytes());
    seal(cipher, 1u8, 1u32, ctr, &pt)
}

/// Requester opens a sealed card, verifies WHO, and returns (authentic, card_word).
fn open_card(cipher: &ChaCha20Poly1305, frame: &[u8]) -> (bool, u32) {
    let res = open(cipher, 1u8, frame).expect("card frame opens");
    let mut pk = [0u8; 32];
    pk.copy_from_slice(&res[D_PUBKEY..D_PUBKEY + 32]);
    let claimed_exec = read_u32(&res, D_EXEC);
    let card_word = read_u32(&res, D_CARD);
    let mut sb = [0u8; 64];
    sb.copy_from_slice(&res[D_SIG..D_SIG + 64]);
    let sig_ok = VerifyingKey::from_bytes(&pk).unwrap().verify(&card_msg(card_word), &Signature::from_bytes(&sb)).is_ok();
    let who = ident::who_ok(sig_ok as u32, claimed_exec, executor_id(&pk));
    (who, card_word)
}

fn main() {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&[7u8; 32]));
    let sk = SigningKey::from_bytes(&[7u8; 32]);
    let pubkey = sk.verifying_key().to_bytes();
    let exec_id = executor_id(&pubkey);

    // Host A advertises: family GF-T, widths {8,16}, ops {mul, add}.
    let fam_gft = card::family_bit(card::FMT_GFT);
    let card_a = card::make_card_ops(fam_gft, 8 | 16, card::op_bit(card::GF_OP_MUL) | card::op_bit(card::GF_OP_ADD));
    let frame_a = seal_card(&cipher, 0x6001, &sk, &pubkey, exec_id, card_a);
    assert!(cf::frame_len_ok(frame_a.len()) && a2a::is_a2a(1, a2a::A2A_PORT));

    // Requester opens the advertisement, verifies WHO, then routes by capability.
    let (who_a, card_rx) = open_card(&cipher, &frame_a);
    assert!(who_a, "the capability card is authentically the host's (WHO)");

    // POSITIVE: GF-T16 mul and GF-T8 mul are advertised -> routable to this host.
    assert!(card::can_serve_skill_op(card_rx, skill(card::HI_GFT16, card::GF_OP_MUL)), "GF-T16 mul is served -> route");
    assert!(card::can_serve_skill_op(card_rx, skill(card::HI_GFT16, card::GF_OP_ADD)), "GF-T16 add is served -> route");
    assert!(card::can_serve_skill_op(card_rx, skill(card::HI_GFT8, card::GF_OP_MUL)), "GF-T8 mul is served -> route");

    // NEGATIVE family: GF16-BINARY (HI_GF16) is a different format -> NOT served.
    assert!(!card::can_serve_skill_op(card_rx, skill(card::HI_GF16, card::GF_OP_MUL)), "GF16-binary is a family this host did not advertise -> not routed");
    // NEGATIVE op: an op the host did not advertise (0x12, not mul/add) -> NOT served.
    assert!(!card::can_serve_skill_op(card_rx, skill(card::HI_GFT16, 0x12)), "an unadvertised op -> not routed");

    // NEGATIVE width: a second host B advertises ONLY width 16. A GF-T8 (width 8) task
    // is NOT routed to it, even though it serves the GF-T family + mul.
    let card_b = card::make_card_ops(fam_gft, 16, card::op_bit(card::GF_OP_MUL));
    let frame_b = seal_card(&cipher, 0x6002, &sk, &pubkey, exec_id, card_b);
    let (who_b, card_b_rx) = open_card(&cipher, &frame_b);
    assert!(who_b);
    assert!(card::can_serve_skill_op(card_b_rx, skill(card::HI_GFT16, card::GF_OP_MUL)), "host B serves GF-T16 mul");
    assert!(!card::can_serve_skill_op(card_b_rx, skill(card::HI_GFT8, card::GF_OP_MUL)), "host B did not advertise width 8 -> GF-T8 not routed");

    // NEGATIVE forged advertisement: a card signed by the WRONG key fails WHO -> ignored.
    let wrong_sk = SigningKey::from_bytes(&[9u8; 32]);
    let mut forged: Vec<u8> = Vec::new();
    forged.extend_from_slice(&pubkey); // claims host A's pubkey...
    forged.extend_from_slice(&exec_id.to_be_bytes());
    forged.extend_from_slice(&card_a.to_be_bytes());
    forged.extend_from_slice(&wrong_sk.sign(&card_msg(card_a)).to_bytes()); // ...but signed by another key
    let (who_forged, _) = open_card(&cipher, &seal(&cipher, 1u8, 1u32, 0x6003, &forged));
    assert!(!who_forged, "a card signed by the wrong key fails WHO -> forged advertisement ignored");

    println!("capability-advertised routing over the sealed mesh:");
    println!("  host A card: family GF-T, widths {{8,16}}, ops {{mul,add}} (signed, WHO ok)");
    println!("  route GF-T16 mul / GF-T8 mul / GF-T16 add -> served; GF16-binary / op 0x12 -> NOT served");
    println!("  host B card: widths {{16}} only -> GF-T8 task NOT routed to it");
    println!("  forged card (wrong signer) -> WHO fails -> advertisement ignored");
    println!("OK: a task is routed only to a host that authentically advertised the (family, width, op), over a real sealed datagram");
}
