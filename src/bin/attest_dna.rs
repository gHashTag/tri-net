// attest_dna — A2 Device-DNA runtime stub. Reads the Xilinx DNA_PORT (on
// hardware) or a fake u57/u96 value (in -sim mode), signs a challenge, and
// echoes a response frame.
//
// This binary is standalone (like admin_httpd) — it embeds the generated
// spec file via #[path] and does NOT depend on the crate root.
//
// Ratchet status (skill v1.1 §Sandbox-vs-hardware):
//   1. sim         — DONE via this stub + spec tests
//   2. synth       — NOT DONE (needs Vivado / openXC7 build for AX7203)
//   3. one-board   — NOT DONE (needs P203 Mini flash)
//   4. two-board   — NOT DONE (needs 2× P203 Mini)
// -> Do NOT claim chip-attest binding until step 4 passes.
//
// phi^2 + 1/phi^2 = 3 | TRINITY

#![allow(clippy::needless_return, dead_code, unused_parens)]

#[path = "../../gen/rust/device_dna.rs"]
mod device_dna_gen;

use std::env;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::time::{SystemTime, UNIX_EPOCH};

fn read_dna_sim(node_id: u16) -> (u32, u32, u8) {
    // Deterministic per-node fake DNA. Two boards -> two DNAs. Anti-anchor:
    // this is -sim, not a measurement. Real read requires PL bitstream.
    let seed = 0xA57B_0000u32.wrapping_add(node_id as u32);
    // Fake 57-bit value: hi word masked to top 25 bits used.
    let hi = seed;
    let lo = seed.wrapping_mul(0x9E37_79B1);
    (hi & 0x01FF_FFFF, lo, device_dna_gen::DNA_BITS_7SERIES)
}

fn now_unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn build_transcript(nonce: &[u8; 16], ts_secs: u64, dna_hi: u32, dna_lo: u32, dna_bits: u8) -> [u8; 33] {
    let mut out = [0u8; 33];
    out[..16].copy_from_slice(nonce);
    out[16..24].copy_from_slice(&ts_secs.to_be_bytes());
    out[24] = dna_bits;
    out[25..29].copy_from_slice(&dna_hi.to_be_bytes());
    out[29..33].copy_from_slice(&dna_lo.to_be_bytes());
    out
}

// -sim "signature" is a 64-byte deterministic hash of the transcript. NOT
// Ed25519. When hardware key store is wired, this is replaced by the real
// ed25519_dalek sign. Kept as a placeholder that only proves the framing.
fn sim_sign(transcript: &[u8]) -> [u8; 64] {
    let mut sig = [0u8; 64];
    // Two rounds of a Fowler-Noll-Vo variant, folded into 64 bytes.
    let mut h: u64 = 0xCBF2_9CE4_8422_2325;
    for &b in transcript {
        h ^= b as u64;
        h = h.wrapping_mul(0x100_0000_01B3);
    }
    for i in 0..8 {
        let shift = (i * 8) as u32;
        sig[i] = ((h >> shift) & 0xFF) as u8;
        sig[i + 8]  = ((h >> shift) & 0xFF) as u8 ^ 0xA5;
        sig[i + 16] = ((h >> shift) & 0xFF) as u8 ^ 0x5A;
        sig[i + 24] = ((h >> shift) & 0xFF) as u8 ^ 0x3C;
        sig[i + 32] = ((h >> shift) & 0xFF) as u8 ^ 0xC3;
        sig[i + 40] = ((h >> shift) & 0xFF) as u8 ^ 0x11;
        sig[i + 48] = ((h >> shift) & 0xFF) as u8 ^ 0xEE;
        sig[i + 56] = ((h >> shift) & 0xFF) as u8 ^ 0x77;
    }
    sig
}

fn handle(mut stream: std::net::TcpStream, node_id: u16) -> std::io::Result<()> {
    let mut buf = [0u8; 32];
    let n = stream.read(&mut buf)?;
    if n < 25 { return Ok(()); }
    if !device_dna_gen::challenge_frame_len_valid(n) {
        return Ok(());
    }
    if buf[0] != device_dna_gen::MSG_CHALLENGE {
        return Ok(());
    }
    let mut nonce = [0u8; 16];
    nonce.copy_from_slice(&buf[1..17]);
    // ts is 8 bytes BE, from buf[17..25]
    let ts = u64::from_be_bytes(buf[17..25].try_into().unwrap());
    let now = now_unix_secs();
    // Freshness gate using spec predicate at 32-bit slice (spec is u32).
    let now_lo = (now & 0xFFFF_FFFF) as u32;
    let ts_lo  = (ts & 0xFFFF_FFFF) as u32;
    if !device_dna_gen::timestamp_fresh(now_lo, ts_lo) {
        // Silently drop replayed challenges.
        return Ok(());
    }
    let (dna_hi, dna_lo, dna_bits) = read_dna_sim(node_id);
    if !device_dna_gen::dna_bit_count_valid(dna_bits) {
        return Ok(());
    }
    let transcript = build_transcript(&nonce, ts, dna_hi, dna_lo, dna_bits);
    let sig = sim_sign(&transcript);

    let mut out = Vec::with_capacity(98);
    out.push(device_dna_gen::MSG_RESPONSE);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ts.to_be_bytes());
    out.push(dna_bits);
    out.extend_from_slice(&dna_hi.to_be_bytes());
    out.extend_from_slice(&dna_lo.to_be_bytes());
    out.extend_from_slice(&sig);
    assert!(device_dna_gen::response_frame_len_valid(out.len()));
    stream.write_all(&out)?;
    Ok(())
}

fn main() -> std::io::Result<()> {
    let node_id: u16 = env::var("TRINET_NODE").ok()
        .and_then(|s| s.parse().ok()).unwrap_or(11);
    let bind = env::var("ATTEST_DNA_BIND").unwrap_or_else(|_| "127.0.0.1:9601".into());
    eprintln!("[attest_dna] node={node_id} listening on {bind} (-sim mode, no PL)");
    let listener = TcpListener::bind(&bind)?;
    for stream in listener.incoming() {
        match stream {
            Ok(s) => {
                let _ = handle(s, node_id);
            }
            Err(e) => eprintln!("[attest_dna] accept err: {e}"),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sim_dna_is_deterministic_per_node() {
        let a1 = read_dna_sim(11);
        let a2 = read_dna_sim(11);
        assert_eq!(a1, a2, "same node -> same DNA in -sim");
    }

    #[test]
    fn different_nodes_have_different_dnas() {
        let a = read_dna_sim(11);
        let b = read_dna_sim(12);
        assert_ne!((a.0, a.1), (b.0, b.1), "distinct nodes -> distinct sim DNAs");
    }

    #[test]
    fn transcript_layout_matches_spec_regions() {
        let nonce = [0xAAu8; 16];
        let ts: u64 = 0x1122_3344_5566_7788;
        let (hi, lo, bits) = (0x00A5_A5A5u32, 0xDEAD_BEEFu32, device_dna_gen::DNA_BITS_7SERIES);
        let t = build_transcript(&nonce, ts, hi, lo, bits);
        // Every nonce byte matches.
        for i in 0..16 { assert_eq!(t[i], 0xAA, "nonce byte {i}"); }
        // ts BE.
        assert_eq!(t[16], 0x11);
        assert_eq!(t[23], 0x88);
        // dna_bits.
        assert_eq!(t[24], bits);
        // dna_hi BE.
        assert_eq!(t[25], 0x00);
        assert_eq!(t[26], 0xA5);
        assert_eq!(t[27], 0xA5);
        assert_eq!(t[28], 0xA5);
        // dna_lo BE.
        assert_eq!(t[29], 0xDE);
        assert_eq!(t[32], 0xEF);
    }

    #[test]
    fn sim_signature_length_matches_ed25519_shape() {
        let nonce = [1u8; 16];
        let t = build_transcript(&nonce, 42, 1, 2, device_dna_gen::DNA_BITS_7SERIES);
        let s = sim_sign(&t);
        assert_eq!(s.len(), 64, "sim sig is Ed25519-shaped 64 bytes");
        // NOT the same across two different transcripts.
        let t2 = build_transcript(&nonce, 43, 1, 2, device_dna_gen::DNA_BITS_7SERIES);
        let s2 = sim_sign(&t2);
        assert_ne!(s, s2, "distinct transcripts -> distinct sim sigs");
    }

    #[test]
    fn spec_predicates_visible() {
        assert!(device_dna_gen::challenge_frame_len_valid(25));
        assert!(device_dna_gen::response_frame_len_valid(98));
        assert!(device_dna_gen::chip_attest_binding(device_dna_gen::DNA_BITS_7SERIES, 64));
    }
}
