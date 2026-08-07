//! sha256_gen_executed -- the LAST step of the tri_sha256 gap: actually EXECUTE the committed
//! generated code under `cargo test`. sha256_kat_anchor pins the algorithm (independent FIPS 180-4
//! == KAT == sha2 crate) and the sha256-gen-check workflow pins spec<->gen sync; this closes the
//! remaining hole by running gen/rust/tri_sha256.rs itself against the sha2 crate.
//!
//! Semantics caveat that shapes this test: t27 u32 arithmetic is WRAPPING (hardware semantics),
//! but `t27c gen-rust` emits bare `+`, so the gen only computes correctly where Rust `+` wraps --
//! i.e. with overflow-checks off, the release semantics the production digest bins are built with
//! (under debug overflow-checks the abc KAT panics on the first wrapped add; upstream t27 issue).
//! So the digest KATs compile the ACTUAL committed gen with `rustc -O` in a subprocess and run
//! them there, while the overflow-free sha256_pad2_word is exercised by direct include.

use sha2::{Digest, Sha256};
use std::process::Command;

#[allow(unused_parens, dead_code, clippy::all)]
mod sha_gen {
    include!("../gen/rust/tri_sha256.rs");
}

fn digest_words(msg: &[u8]) -> [u32; 8] {
    let d = Sha256::digest(msg);
    let mut w = [0u32; 8];
    for (i, c) in d.chunks_exact(4).enumerate() {
        w[i] = u32::from_be_bytes([c[0], c[1], c[2], c[3]]);
    }
    w
}

fn words_csv(w: &[u32; 8]) -> String {
    w.iter()
        .map(|x| x.to_string())
        .collect::<Vec<_>>()
        .join(",")
}

#[test]
fn the_generated_pad2_layout_is_the_fips_trailing_block() {
    // Word 0 carries the 0x80 marker, word 15 the total bit length, everything else zero.
    assert_eq!(sha_gen::sha256_pad2_word(0, 512), 0x8000_0000, "pad marker");
    assert_eq!(sha_gen::sha256_pad2_word(15, 512), 512, "bit length");
    for idx in 1..15u32 {
        assert_eq!(sha_gen::sha256_pad2_word(idx, 512), 0, "zero fill at {idx}");
    }
}

#[test]
fn the_generated_digest_matches_real_sha256_under_release_semantics() {
    // Expected values come from the trusted sha2 crate at test run time (not hardcoded).
    let abc = digest_words(b"abc");
    let two_block = digest_words(&[0x61u8; 64]);

    let gen_path = concat!(env!("CARGO_MANIFEST_DIR"), "/gen/rust/tri_sha256.rs");
    let harness = format!(
        r#"
#[allow(unused_parens, dead_code)]
mod sha_gen {{ include!("{gen_path}"); }}
fn main() {{
    let abc: Vec<u32> = std::env::args().nth(1).unwrap().split(',').map(|s| s.parse().unwrap()).collect();
    let two: Vec<u32> = std::env::args().nth(2).unwrap().split(',').map(|s| s.parse().unwrap()).collect();
    // sha256("abc"): one padded block, w0 = 0x61626380, w15 = 24.
    for i in 0..8u32 {{
        let got = sha_gen::sha256_word(0x61626380, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x18, i);
        assert_eq!(got, abc[i as usize], "abc word {{i}}");
    }}
    // 64 x 'a': block 1 is data, block 2 is the pad2 layout, chained through sha256_compress.
    let mut s = [0u32; 8];
    for k in 0..8u32 {{
        s[k as usize] = sha_gen::sha256_word(
            0x61616161, 0x61616161, 0x61616161, 0x61616161, 0x61616161, 0x61616161, 0x61616161,
            0x61616161, 0x61616161, 0x61616161, 0x61616161, 0x61616161, 0x61616161, 0x61616161,
            0x61616161, 0x61616161, k);
    }}
    let mut b2 = [0u32; 16];
    for idx in 0..16u32 {{ b2[idx as usize] = sha_gen::sha256_pad2_word(idx, 512); }}
    for j in 0..8u32 {{
        let got = sha_gen::sha256_compress(
            s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], b2[0], b2[1], b2[2], b2[3], b2[4],
            b2[5], b2[6], b2[7], b2[8], b2[9], b2[10], b2[11], b2[12], b2[13], b2[14], b2[15], j);
        assert_eq!(got, two[j as usize], "two-block word {{j}}");
    }}
    println!("GEN_KAT_OK");
}}
"#
    );

    let dir = std::env::temp_dir().join("trinet_sha256_gen_executed");
    std::fs::create_dir_all(&dir).expect("temp dir");
    let src = dir.join("harness.rs");
    let bin = dir.join("harness_bin");
    std::fs::write(&src, harness).expect("write harness");

    // -O gives the wrapping release semantics; the committed gen is compiled AS IS.
    let compile = Command::new("rustc")
        .args(["-O", "--edition", "2021"])
        .arg(&src)
        .arg("-o")
        .arg(&bin)
        .output()
        .expect("run rustc");
    assert!(
        compile.status.success(),
        "the committed gen must compile: {}",
        String::from_utf8_lossy(&compile.stderr)
    );

    let run = Command::new(&bin)
        .arg(words_csv(&abc))
        .arg(words_csv(&two_block))
        .output()
        .expect("run harness");
    assert!(
        run.status.success() && String::from_utf8_lossy(&run.stdout).contains("GEN_KAT_OK"),
        "generated SHA-256 must reproduce the sha2-crate digests: {}",
        String::from_utf8_lossy(&run.stderr)
    );
}
