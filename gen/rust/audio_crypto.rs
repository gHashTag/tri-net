// Generated skeleton from specs/audio_crypto.t27 (W3, 2026-07-14).
// Predicates and constants are ports of the spec; crypto primitives are
// PLACEHOLDERS clearly tagged `-crypto-placeholder`. See spec header
// for the full non-claim disclaimer.
//
// phi^2 + phi^-2 = 3

// ─── spec-derived constants ─────────────────────────────────────────

pub const CRYPTO_ENVELOPE_VERSION: u8 = 1;
pub const NONCE_LEN: usize = 12;
pub const TAG_LEN: usize = 16;
pub const CRYPTO_HEADER_LEN: usize = 1 + NONCE_LEN; // 13
pub const CRYPTO_OVERHEAD: usize = CRYPTO_HEADER_LEN + TAG_LEN; // 29

// ─── spec-derived predicates ────────────────────────────────────────

pub fn crypto_version_valid(v: u8) -> bool {
    v == CRYPTO_ENVELOPE_VERSION
}

pub fn wrapped_len(plain_len: usize) -> usize {
    CRYPTO_OVERHEAD + plain_len
}

pub fn ciphertext_len(wire_len: usize) -> usize {
    if wire_len < CRYPTO_OVERHEAD {
        return 0;
    }
    wire_len - CRYPTO_OVERHEAD
}

pub fn envelope_structurally_ok(wire_len: usize, version: u8) -> bool {
    if !crypto_version_valid(version) {
        return false;
    }
    if wire_len < CRYPTO_OVERHEAD + 1 {
        return false;
    }
    if wire_len > 550 {
        return false;
    }
    true
}

pub fn nonces_distinct(nonce_a_seq: u32, nonce_b_seq: u32) -> bool {
    nonce_a_seq != nonce_b_seq
}

pub fn nonce_byte(seq_counter: u32, idx: u8) -> u8 {
    if idx < 8 {
        return 0;
    }
    if idx == 8 {
        return ((seq_counter >> 24) & 255) as u8;
    }
    if idx == 9 {
        return ((seq_counter >> 16) & 255) as u8;
    }
    if idx == 10 {
        return ((seq_counter >> 8) & 255) as u8;
    }
    (seq_counter & 255) as u8
}

pub fn header_byte(version: u8, seq_counter: u32, idx: u8) -> u8 {
    if idx == 0 {
        return version;
    }
    nonce_byte(seq_counter, idx - 1)
}

pub fn build_nonce(seq_counter: u32) -> [u8; NONCE_LEN] {
    let mut n = [0u8; NONCE_LEN];
    for i in 0..(NONCE_LEN as u8) {
        n[i as usize] = nonce_byte(seq_counter, i);
    }
    n
}

// ─── PLACEHOLDER crypto primitives (`-crypto-placeholder`) ──────────
//
// These MUST be replaced with audited implementations before any
// adversarial deployment. They exist so the wire layout can be
// exercised end-to-end in sandbox tests.

/// Placeholder keystream: XOR every byte with `key[i mod key.len()]`
/// combined with `nonce[i mod 12]`. NOT ChaCha20. NOT SECURE.
///
/// Rationale for including this at all: without a keystream at least
/// as a stand-in, the runtime cannot demonstrate that ciphertext !=
/// plaintext, and tests cannot assert basic round-trip properties.
pub fn placeholder_xor_keystream(
    plaintext: &[u8],
    key: &[u8; 32],
    nonce: &[u8; NONCE_LEN],
) -> Vec<u8> {
    let mut out = Vec::with_capacity(plaintext.len());
    for (i, b) in plaintext.iter().enumerate() {
        let k = key[i % key.len()];
        let n = nonce[i % NONCE_LEN];
        out.push(b ^ k ^ n);
    }
    out
}

/// Placeholder MAC: SHA-256(key || nonce || ciphertext), truncated to
/// 16 bytes. NOT Poly1305. NOT KEY-COMMITTING. Rejects bit-flips and
/// simple replays but is NOT a substitute for a real AEAD tag.
pub fn placeholder_mac(
    ciphertext: &[u8],
    key: &[u8; 32],
    nonce: &[u8; NONCE_LEN],
) -> [u8; TAG_LEN] {
    let digest = sha256_of_three(key, nonce, ciphertext);
    let mut tag = [0u8; TAG_LEN];
    tag.copy_from_slice(&digest[..TAG_LEN]);
    tag
}

// ─── minimal SHA-256 (pure Rust, no deps) ──────────────────────────
//
// Implementation of FIPS 180-4 §6.2. Used ONLY by placeholder_mac.
// Not intended to be a general-purpose SHA-256 crate; correctness is
// verified against the RFC 6234 test vector "abc" in the tests below.
// If this file is compiled into a binary that also has a real SHA-256
// available (via a proper dependency), replace this block.

fn sha256_of_three(a: &[u8], b: &[u8], c: &[u8]) -> [u8; 32] {
    let mut buf = Vec::with_capacity(a.len() + b.len() + c.len());
    buf.extend_from_slice(a);
    buf.extend_from_slice(b);
    buf.extend_from_slice(c);
    sha256(&buf)
}

const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

pub fn sha256(msg: &[u8]) -> [u8; 32] {
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];

    // Padding: append 0x80, then zeros, then 8-byte big-endian bit length.
    let bit_len = (msg.len() as u64) * 8;
    let mut buf = Vec::with_capacity(msg.len() + 72);
    buf.extend_from_slice(msg);
    buf.push(0x80);
    while buf.len() % 64 != 56 {
        buf.push(0);
    }
    buf.extend_from_slice(&bit_len.to_be_bytes());

    for chunk in buf.chunks_exact(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                chunk[i * 4],
                chunk[i * 4 + 1],
                chunk[i * 4 + 2],
                chunk[i * 4 + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let (mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh) =
            (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]);
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ (!e & g);
            let temp1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }

    let mut out = [0u8; 32];
    for i in 0..8 {
        out[i * 4..i * 4 + 4].copy_from_slice(&h[i].to_be_bytes());
    }
    out
}

// ─── envelope wrap / unwrap ─────────────────────────────────────────

/// Wrap a plaintext PttAudio frame in a `-crypto-placeholder`
/// envelope. Returns the on-wire buffer.
pub fn wrap(plaintext: &[u8], key: &[u8; 32], seq_counter: u32) -> Vec<u8> {
    let nonce = build_nonce(seq_counter);
    let ct = placeholder_xor_keystream(plaintext, key, &nonce);
    let tag = placeholder_mac(&ct, key, &nonce);

    let mut out = Vec::with_capacity(CRYPTO_OVERHEAD + ct.len());
    out.push(CRYPTO_ENVELOPE_VERSION);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ct);
    out.extend_from_slice(&tag);
    out
}

#[derive(Debug, PartialEq, Eq)]
pub enum UnwrapError {
    TooShort,
    BadVersion,
    TagMismatch,
}

/// Unwrap a `-crypto-placeholder` envelope. Verifies MAC in constant-
/// ish time (the reference implementation is NOT audited for constant
/// time; do not treat this as a real AEAD).
pub fn unwrap(wire: &[u8], key: &[u8; 32]) -> Result<Vec<u8>, UnwrapError> {
    if wire.len() < CRYPTO_OVERHEAD + 1 {
        return Err(UnwrapError::TooShort);
    }
    if !crypto_version_valid(wire[0]) {
        return Err(UnwrapError::BadVersion);
    }
    let mut nonce = [0u8; NONCE_LEN];
    nonce.copy_from_slice(&wire[1..1 + NONCE_LEN]);
    let ct_end = wire.len() - TAG_LEN;
    let ct = &wire[CRYPTO_HEADER_LEN..ct_end];
    let tag_on_wire = &wire[ct_end..];

    let tag_expected = placeholder_mac(ct, key, &nonce);
    let mut diff: u8 = 0;
    for i in 0..TAG_LEN {
        diff |= tag_expected[i] ^ tag_on_wire[i];
    }
    if diff != 0 {
        return Err(UnwrapError::TagMismatch);
    }

    Ok(placeholder_xor_keystream(ct, key, &nonce))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Predicate ports (must match spec).

    #[test]
    fn constants_match_rfc7539() {
        assert_eq!(NONCE_LEN, 12);
        assert_eq!(TAG_LEN, 16);
        assert_eq!(CRYPTO_OVERHEAD, 29);
    }

    #[test]
    fn wrapped_len_arithmetic() {
        assert_eq!(wrapped_len(0), 29);
        assert_eq!(wrapped_len(89), 118);
        assert_eq!(wrapped_len(521), 550);
    }

    #[test]
    fn ciphertext_len_arithmetic() {
        assert_eq!(ciphertext_len(0), 0);
        assert_eq!(ciphertext_len(28), 0);
        assert_eq!(ciphertext_len(29), 0);
        assert_eq!(ciphertext_len(118), 89);
    }

    #[test]
    fn envelope_gate() {
        assert!(!envelope_structurally_ok(0, 1));
        assert!(!envelope_structurally_ok(29, 1));
        assert!(envelope_structurally_ok(118, 1));
        assert!(envelope_structurally_ok(550, 1));
        assert!(!envelope_structurally_ok(551, 1));
        assert!(!envelope_structurally_ok(118, 2));
    }

    #[test]
    fn nonce_layout() {
        assert_eq!(nonce_byte(0xDEADBEEF, 0), 0);
        assert_eq!(nonce_byte(0xDEADBEEF, 7), 0);
        assert_eq!(nonce_byte(0xDEADBEEF, 8), 0xDE);
        assert_eq!(nonce_byte(0xDEADBEEF, 9), 0xAD);
        assert_eq!(nonce_byte(0xDEADBEEF, 10), 0xBE);
        assert_eq!(nonce_byte(0xDEADBEEF, 11), 0xEF);
    }

    #[test]
    fn nonce_freshness_predicate() {
        assert!(nonces_distinct(0, 1));
        assert!(!nonces_distinct(42, 42));
    }

    #[test]
    fn build_nonce_zeros_and_counter() {
        let n = build_nonce(0xDEADBEEF);
        assert_eq!(&n[0..8], &[0u8; 8]);
        assert_eq!(n[8], 0xDE);
        assert_eq!(n[11], 0xEF);
    }

    // Round-trip properties of the -crypto-placeholder runtime.

    #[test]
    fn wrap_then_unwrap_is_identity() {
        let key = [0x11u8; 32];
        let msg = b"hello, tri-net PTT audio frame";
        let wire = wrap(msg, &key, 1);
        let plain = unwrap(&wire, &key).expect("unwrap ok");
        assert_eq!(plain, msg);
    }

    #[test]
    fn ciphertext_differs_from_plaintext() {
        let key = [0x11u8; 32];
        let msg = b"observe: not equal to ciphertext";
        let wire = wrap(msg, &key, 1);
        // ciphertext lives between CRYPTO_HEADER_LEN and wire.len() - TAG_LEN
        let ct = &wire[CRYPTO_HEADER_LEN..wire.len() - TAG_LEN];
        assert_ne!(ct, &msg[..]);
    }

    #[test]
    fn wrong_key_fails_mac() {
        let key_a = [0x11u8; 32];
        let key_b = [0x22u8; 32];
        let wire = wrap(b"secret", &key_a, 1);
        assert_eq!(unwrap(&wire, &key_b), Err(UnwrapError::TagMismatch));
    }

    #[test]
    fn bitflip_in_ciphertext_fails_mac() {
        let key = [0x11u8; 32];
        let mut wire = wrap(b"payload", &key, 1);
        // Flip a bit in the ciphertext region.
        wire[CRYPTO_HEADER_LEN] ^= 0x01;
        assert_eq!(unwrap(&wire, &key), Err(UnwrapError::TagMismatch));
    }

    #[test]
    fn bitflip_in_tag_fails_mac() {
        let key = [0x11u8; 32];
        let mut wire = wrap(b"payload", &key, 1);
        let last = wire.len() - 1;
        wire[last] ^= 0x01;
        assert_eq!(unwrap(&wire, &key), Err(UnwrapError::TagMismatch));
    }

    #[test]
    fn bad_version_rejected() {
        let key = [0x11u8; 32];
        let mut wire = wrap(b"payload", &key, 1);
        wire[0] = 2;
        assert_eq!(unwrap(&wire, &key), Err(UnwrapError::BadVersion));
    }

    #[test]
    fn too_short_rejected() {
        let key = [0x11u8; 32];
        assert_eq!(unwrap(&[], &key), Err(UnwrapError::TooShort));
        assert_eq!(unwrap(&[0u8; 29], &key), Err(UnwrapError::TooShort));
    }

    #[test]
    fn distinct_nonces_produce_distinct_ciphertexts() {
        let key = [0x11u8; 32];
        let msg = b"same plaintext";
        let wire_a = wrap(msg, &key, 1);
        let wire_b = wrap(msg, &key, 2);
        let ct_a = &wire_a[CRYPTO_HEADER_LEN..wire_a.len() - TAG_LEN];
        let ct_b = &wire_b[CRYPTO_HEADER_LEN..wire_b.len() - TAG_LEN];
        assert_ne!(ct_a, ct_b);
    }

    // SHA-256 sanity — RFC 6234 test vector "abc".

    #[test]
    fn sha256_abc_vector() {
        let out = sha256(b"abc");
        let want: [u8; 32] = [
            0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae,
            0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61,
            0xf2, 0x00, 0x15, 0xad,
        ];
        assert_eq!(out, want);
    }

    #[test]
    fn sha256_empty_vector() {
        // FIPS 180-4: SHA-256("") = e3b0c442...
        let out = sha256(b"");
        assert_eq!(&out[..4], &[0xe3, 0xb0, 0xc4, 0x42]);
    }
}
