//! sha256_kat_anchor -- CI anchor for the SHA-256 the whole ring's hashing rests on (receipt
//! digests, input-operand binding, the batch merkle). The hand-written spec SHA-256 (tri_sha256) is
//! used by production digest bins but its gen is not CI-buildable, and its `abc` KAT lives only in
//! un-executed spec blocks; the batch merkle uses the sha2 crate. Nothing tied these together with a
//! CI-executed ground truth. This implements SHA-256 INDEPENDENTLY (a second ruler, the NIST FIPS
//! 180-4 algorithm tri_sha256 encodes), and pins: it reproduces the canonical KAT vectors; it agrees
//! with the trusted sha2 crate across message lengths and block boundaries; and its `abc` digest
//! words are EXACTLY the h0..h7 the spec's tri_sha256 abc-KAT asserts (so the spec's expected values
//! are the correct SHA-256, not a drifted constant).

use sha2::{Digest, Sha256};

// ---- an independent SHA-256 (NIST FIPS 180-4) ----
const H0: [u32; 8] = [
    0x6a09_e667,
    0xbb67_ae85,
    0x3c6e_f372,
    0xa54f_f53a,
    0x510e_527f,
    0x9b05_688c,
    0x1f83_d9ab,
    0x5be0_cd19,
];
const K: [u32; 64] = [
    0x428a_2f98,
    0x7137_4491,
    0xb5c0_fbcf,
    0xe9b5_dba5,
    0x3956_c25b,
    0x59f1_11f1,
    0x923f_82a4,
    0xab1c_5ed5,
    0xd807_aa98,
    0x1283_5b01,
    0x2431_85be,
    0x550c_7dc3,
    0x72be_5d74,
    0x80de_b1fe,
    0x9bdc_06a7,
    0xc19b_f174,
    0xe49b_69c1,
    0xefbe_4786,
    0x0fc1_9dc6,
    0x240c_a1cc,
    0x2de9_2c6f,
    0x4a74_84aa,
    0x5cb0_a9dc,
    0x76f9_88da,
    0x983e_5152,
    0xa831_c66d,
    0xb003_27c8,
    0xbf59_7fc7,
    0xc6e0_0bf3,
    0xd5a7_9147,
    0x06ca_6351,
    0x1429_2967,
    0x27b7_0a85,
    0x2e1b_2138,
    0x4d2c_6dfc,
    0x5338_0d13,
    0x650a_7354,
    0x766a_0abb,
    0x81c2_c92e,
    0x9272_2c85,
    0xa2bf_e8a1,
    0xa81a_664b,
    0xc24b_8b70,
    0xc76c_51a3,
    0xd192_e819,
    0xd699_0624,
    0xf40e_3585,
    0x106a_a070,
    0x19a4_c116,
    0x1e37_6c08,
    0x2748_774c,
    0x34b0_bcb5,
    0x391c_0cb3,
    0x4ed8_aa4a,
    0x5b9c_ca4f,
    0x682e_6ff3,
    0x748f_82ee,
    0x78a5_636f,
    0x84c8_7814,
    0x8cc7_0208,
    0x90be_fffa,
    0xa450_6ceb,
    0xbef9_a3f7,
    0xc671_78f2,
];

fn sha256(msg: &[u8]) -> [u8; 32] {
    let mut h = H0;
    // pad: 0x80, then zeros to 56 mod 64, then 64-bit big-endian bit length.
    let bitlen = (msg.len() as u64) * 8;
    let mut data = msg.to_vec();
    data.push(0x80);
    while data.len() % 64 != 56 {
        data.push(0);
    }
    data.extend_from_slice(&bitlen.to_be_bytes());

    for block in data.as_chunks::<64>().0 {
        let mut w = [0u32; 64];
        for (i, wi) in w.iter_mut().enumerate().take(16) {
            let b = i * 4;
            *wi = u32::from_be_bytes([block[b], block[b + 1], block[b + 2], block[b + 3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let t1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (hv, v) in h.iter_mut().zip([a, b, c, d, e, f, g, hh]) {
            *hv = hv.wrapping_add(v);
        }
    }
    let mut out = [0u8; 32];
    for (i, word) in h.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&word.to_be_bytes());
    }
    out
}

fn crate_sha256(msg: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(msg);
    h.finalize().into()
}

#[test]
fn the_independent_sha256_reproduces_the_canonical_kat_vectors() {
    // SHA-256("abc") -- the classic FIPS 180-4 example.
    assert_eq!(
        sha256(b"abc"),
        [
            0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae,
            0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61,
            0xf2, 0x00, 0x15, 0xad
        ],
        "SHA-256(abc)"
    );
    // SHA-256("") -- the empty string.
    assert_eq!(
        sha256(b""),
        [
            0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f,
            0xb9, 0x24, 0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c, 0xa4, 0x95, 0x99, 0x1b,
            0x78, 0x52, 0xb8, 0x55
        ],
        "SHA-256(empty)"
    );
}

#[test]
fn the_abc_digest_words_equal_the_spec_tri_sha256_kat() {
    // Cross-reference: the h0..h7 the spec's tri_sha256 abc-KAT asserts are EXACTLY the correct
    // SHA-256("abc") words -- so the spec's expected values are anchored to real SHA-256.
    let d = sha256(b"abc");
    let words: Vec<u32> = d
        .as_chunks::<4>()
        .0
        .iter()
        .map(|c| u32::from_be_bytes([c[0], c[1], c[2], c[3]]))
        .collect();
    let spec_kat = [
        0xBA78_16BF,
        0x8F01_CFEA,
        0x4141_40DE,
        0x5DAE_2223,
        0xB003_61A3,
        0x9617_7A9C,
        0xB410_FF61,
        0xF200_15AD,
    ];
    assert_eq!(
        words.as_slice(),
        &spec_kat,
        "spec abc-KAT h0..h7 are real SHA-256"
    );
}

#[test]
fn the_independent_sha256_agrees_with_the_sha2_crate_across_lengths_and_blocks() {
    // Two independent rulers (hand FIPS 180-4 vs the sha2 crate) must agree at every length,
    // including exactly on block boundaries (55/56/64 bytes exercise the two-block padding path).
    for len in [0usize, 1, 3, 32, 55, 56, 63, 64, 65, 100, 128, 191, 200] {
        let msg: Vec<u8> = (0..len)
            .map(|i| (i as u32).wrapping_mul(2_654_435_761) as u8)
            .collect();
        assert_eq!(sha256(&msg), crate_sha256(&msg), "mismatch at length {len}");
    }
}
