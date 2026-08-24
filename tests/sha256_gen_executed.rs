//! sha256_gen_executed -- EXECUTE the committed tri_sha256 generated code under `cargo test`.
//! sha256_kat_anchor pins the algorithm (independent FIPS 180-4 == KAT == sha2 crate) and the
//! sha256-gen-check workflow pins spec<->gen sync; this runs gen/rust/tri_sha256.rs itself against
//! the sha2 crate: the abc KAT through sha256_word, and a full two-block message through
//! sha256_word + sha256_pad2_word + sha256_compress (the chained entry points the production
//! digest bins use). The spec uses the explicit wrapping operator `+%` for SHA's mod-2^32 adds
//! (t27's plain `+` is checked, matching the Zig backend), so the gen computes correctly under
//! debug overflow-checks and is called directly -- no release-mode subprocess needed.

#[cfg(not(clippy))]
use sha2::{Digest, Sha256};

// clippy's analysis blows up on this include (100+ CPU-minutes, vs seconds for
// rustc) -- the 312 chained `.wrapping_add()` calls of the unrolled compress
// rounds trigger a superlinear lint pass. Skip the module (and the tests that
// use it) under clippy; `cargo test` still compiles and executes everything.
#[cfg(not(clippy))]
#[allow(unused_parens, dead_code)]
mod sha_gen {
    include!("../gen/rust/tri_sha256.rs");
}

#[cfg(not(clippy))]
fn digest_words(msg: &[u8]) -> [u32; 8] {
    let d = Sha256::digest(msg);
    let mut w = [0u32; 8];
    for (i, c) in d.chunks_exact(4).enumerate() {
        w[i] = u32::from_be_bytes([c[0], c[1], c[2], c[3]]);
    }
    w
}

#[cfg(not(clippy))]
#[test]
fn the_generated_sha256_word_reproduces_the_abc_digest() {
    // "abc" is one padded block: w0 = 0x61626380, w15 = 24 (bit length). Expected words come
    // from the trusted sha2 crate at run time, not hardcoded.
    let expect = digest_words(b"abc");
    for (i, e) in expect.iter().enumerate() {
        let got = sha_gen::sha256_word(
            0x6162_6380,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0x18,
            i as u32,
        );
        assert_eq!(got, *e, "abc digest word {i} from the generated code");
    }
}

#[cfg(not(clippy))]
#[test]
fn the_generated_compress_chains_a_two_block_message_like_real_sha256() {
    // A 64-byte message fills block 1 exactly, so block 2 is pure padding -- the layout
    // sha256_pad2_word encodes. Chain: sha256_word over block 1, then sha256_compress from that
    // state over the padding block; the result must equal the sha2 crate's digest.
    let expect = digest_words(&[0x61u8; 64]); // 64 x 'a'
    let a = 0x6161_6161u32;
    let mut state = [0u32; 8];
    for (k, s) in state.iter_mut().enumerate() {
        *s = sha_gen::sha256_word(a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, k as u32);
    }
    let mut b2 = [0u32; 16];
    for (idx, w) in b2.iter_mut().enumerate() {
        *w = sha_gen::sha256_pad2_word(idx as u32, 512);
    }
    for (j, e) in expect.iter().enumerate() {
        let got = sha_gen::sha256_compress(
            state[0], state[1], state[2], state[3], state[4], state[5], state[6], state[7], b2[0],
            b2[1], b2[2], b2[3], b2[4], b2[5], b2[6], b2[7], b2[8], b2[9], b2[10], b2[11], b2[12],
            b2[13], b2[14], b2[15], j as u32,
        );
        assert_eq!(got, *e, "two-block digest word {j} from the generated code");
    }
}

#[cfg(not(clippy))]
#[test]
fn the_generated_pad2_layout_is_the_fips_trailing_block() {
    // Word 0 carries the 0x80 marker, word 15 the total bit length, everything else zero.
    assert_eq!(sha_gen::sha256_pad2_word(0, 512), 0x8000_0000, "pad marker");
    assert_eq!(sha_gen::sha256_pad2_word(15, 512), 512, "bit length");
    for idx in 1..15u32 {
        assert_eq!(sha_gen::sha256_pad2_word(idx, 512), 0, "zero fill at {idx}");
    }
}
