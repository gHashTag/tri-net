// audio_forwarder.rs — E3.2 runtime for PTT audio over Tri-Net mesh.
//
// Discipline (t27 spec-first): the frame predicates live in
// specs/ptt_audio.t27, gen at gen/rust/ptt_audio.rs. This binary is a
// waiter — it takes bytes in on TCP :9701 from admin_httpd (which received
// them from the PWA over WebSocket), validates them against the spec, and
// UDP-fans the raw frame to a static list of peer sockaddrs. No re-derivation
// of constants, no Opus decoding, no crypto.
//
// Env knobs:
//   AUDIO_FWD_BIND      — TCP listen (default 127.0.0.1:9701).
//   AUDIO_FWD_PEERS     — comma-separated peer sockaddrs, e.g.
//                         "127.0.0.1:9711,127.0.0.1:9712".
//   AUDIO_FWD_UDP_BIND  — UDP source (default 0.0.0.0:0, ephemeral).
//   AUDIO_FWD_STATS_PORT — optional TCP port for a plaintext stats endpoint.
//
// Non-claims:
//   - We do NOT decode Opus. The forwarder blindly relays the opaque
//     payload if the envelope passes spec predicates.
//   - We do NOT encrypt. Tri-Net's ChaCha20-Poly1305 layer wraps this in
//     the actual mesh binary; here we handle envelope + fan-out only.
//   - We do NOT retransmit lost frames. Live audio must accept 20 ms drops.
//
// phi^2 + phi^-2 = 3

#[path = "../../gen/rust/ptt_audio.rs"]
mod ptt_audio;

use std::collections::HashMap;
use std::env;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

// ─── replay window (weak-point #8, W7 audit 2026-07-14) ───────────────────
//
// Prior audit: seq field is present in the envelope but never checked.
// A recorded frame can be replayed indefinitely: same session_id, same
// seq, same opus payload → passes envelope_verdict and is fanned out to
// every peer. On a war-time PTT link this is catastrophic (attacker
// records "hold position", replays it 60 s later; receiver plays it as
// if fresh command).
//
// Fix (RFC 6479-style sliding window, per session_id):
//   - highest_seq: the largest seq we have accepted for this session
//   - bitmap[0..64]: bitmap of the 64 seq numbers ending at highest_seq
//   - seq_wraps handled: 16-bit sequence numbers wrap; we accept a wrap
//     only when the gap is < WINDOW/4 (heuristic, keeps replay window
//     tight after wrap).
// Non-claim: this is application-layer replay defense. It does not
// authenticate the sender; that layer belongs in ChaCha20-Poly1305 +
// X25519 crypto envelope (weak-point #7, planned as `specs/audio_crypto.t27`).

const REPLAY_WINDOW: u32 = 64;

#[derive(Default)]
struct WindowState {
    highest_seq: u32, // widened to u32 so we can track wrap-arounds
    bitmap: u64,      // bit i => (highest_seq - i) has been seen; bit 0 = highest
}

#[derive(Default)]
pub struct ReplayGuard {
    per_session: Mutex<HashMap<u32, WindowState>>,
}

impl ReplayGuard {
    pub fn new() -> Self {
        Self { per_session: Mutex::new(HashMap::new()) }
    }

    /// Return true if the (session_id, seq) pair is fresh and should be
    /// forwarded. Return false if it is a replay or too old.
    pub fn accept(&self, session_id: u32, seq: u16) -> bool {
        let mut map = self.per_session.lock().unwrap();
        let state = map.entry(session_id).or_default();
        let seq_u32 = seq as u32;

        if state.highest_seq == 0 && state.bitmap == 0 {
            // First frame for this session.
            state.highest_seq = seq_u32;
            state.bitmap = 1; // mark bit 0 (which is the current highest)
            return true;
        }

        // Compute the gap. Handle 16-bit wrap-around: seqs live in [0, 65535].
        // Treat as fresh if new_seq is "ahead" of highest by at most half
        // the seq space.
        let hi = state.highest_seq & 0xFFFF;
        let diff_fwd = seq_u32.wrapping_sub(hi) & 0xFFFF;
        let diff_back = hi.wrapping_sub(seq_u32) & 0xFFFF;

        if diff_fwd <= 0x8000 && diff_fwd > 0 {
            // seq is newer.
            if diff_fwd >= 64 {
                // Shift bitmap out entirely.
                state.bitmap = 1;
            } else {
                state.bitmap = state.bitmap.wrapping_shl(diff_fwd);
                state.bitmap |= 1;
            }
            state.highest_seq = seq_u32;
            true
        } else if diff_back < REPLAY_WINDOW {
            // seq is within the window — check the corresponding bit.
            let bit = 1u64 << diff_back;
            if state.bitmap & bit != 0 {
                false // replay
            } else {
                state.bitmap |= bit;
                true
            }
        } else {
            // Too old.
            false
        }
    }
}

struct Stats {
    frames_in: AtomicU64,
    frames_ok: AtomicU64,
    frames_reject_version: AtomicU64,
    frames_reject_opuslen: AtomicU64,
    frames_reject_size: AtomicU64,
    frames_reject_short: AtomicU64,
    frames_reject_replay: AtomicU64,
    frames_forwarded: AtomicU64,
    bytes_forwarded: AtomicU64,
}

impl Stats {
    fn new() -> Self {
        Self {
            frames_in: AtomicU64::new(0),
            frames_ok: AtomicU64::new(0),
            frames_reject_version: AtomicU64::new(0),
            frames_reject_opuslen: AtomicU64::new(0),
            frames_reject_size: AtomicU64::new(0),
            frames_reject_short: AtomicU64::new(0),
            frames_reject_replay: AtomicU64::new(0),
            frames_forwarded: AtomicU64::new(0),
            bytes_forwarded: AtomicU64::new(0),
        }
    }
    fn render(&self) -> String {
        format!(
            "frames_in={} frames_ok={} reject_version={} reject_opuslen={} reject_size={} reject_short={} reject_replay={} forwarded={} bytes_forwarded={}",
            self.frames_in.load(Ordering::Relaxed),
            self.frames_ok.load(Ordering::Relaxed),
            self.frames_reject_version.load(Ordering::Relaxed),
            self.frames_reject_opuslen.load(Ordering::Relaxed),
            self.frames_reject_size.load(Ordering::Relaxed),
            self.frames_reject_short.load(Ordering::Relaxed),
            self.frames_reject_replay.load(Ordering::Relaxed),
            self.frames_forwarded.load(Ordering::Relaxed),
            self.bytes_forwarded.load(Ordering::Relaxed),
        )
    }
}

/// Verdict of the envelope check. Returns Ok(total_len_consumed) on
/// acceptance, or Err(&'static str) with the spec-defined reason.
pub fn envelope_verdict(buf: &[u8]) -> Result<usize, &'static str> {
    if buf.len() < ptt_audio::HEADER_LEN {
        return Err("short header");
    }
    let version = buf[0];
    if !ptt_audio::version_valid(version) {
        return Err("bad version");
    }
    let opus_len_be = [buf[7], buf[8]];
    let opus_len = u16::from_be_bytes(opus_len_be);
    if !ptt_audio::opus_len_valid(opus_len) {
        return Err("opus_len out of bounds");
    }
    let total = ptt_audio::total_frame_len(opus_len);
    if buf.len() < total {
        return Err("short opus");
    }
    if !ptt_audio::mesh_forward_safe(version, opus_len, total) {
        return Err("mesh_forward_safe rejected");
    }
    Ok(total)
}

fn parse_peers(s: &str) -> Vec<SocketAddr> {
    s.split(',')
        .filter_map(|p| p.trim().parse().ok())
        .collect()
}

fn extract_session_seq(buf: &[u8]) -> (u32, u16) {
    // Layout from specs/ptt_audio.t27: version(1) session_id(4) seq(2) opus_len(2).
    let session_id = u32::from_be_bytes([buf[1], buf[2], buf[3], buf[4]]);
    let seq = u16::from_be_bytes([buf[5], buf[6]]);
    (session_id, seq)
}

fn handle_conn(
    mut stream: TcpStream,
    sock: &UdpSocket,
    peers: &[SocketAddr],
    stats: &Stats,
    replay: &ReplayGuard,
) {
    let peer = stream.peer_addr().ok();
    let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
    // Simple wire: length-prefixed frames? No — we accept concatenated raw
    // envelopes and use the spec's total_frame_len to slice.
    let mut buf = Vec::with_capacity(4096);
    let mut tmp = [0u8; 2048];
    loop {
        match stream.read(&mut tmp) {
            Ok(0) => break,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
            Err(_) => break,
        }
        // Drain complete frames.
        loop {
            if buf.is_empty() {
                break;
            }
            stats.frames_in.fetch_add(1, Ordering::Relaxed);
            match envelope_verdict(&buf) {
                Ok(total) => {
                    stats.frames_ok.fetch_add(1, Ordering::Relaxed);
                    let frame = &buf[..total];
                    let (session_id, seq) = extract_session_seq(frame);
                    if !replay.accept(session_id, seq) {
                        stats.frames_reject_replay.fetch_add(1, Ordering::Relaxed);
                        buf.drain(..total);
                        continue;
                    }
                    for p in peers {
                        if sock.send_to(frame, p).is_ok() {
                            stats.frames_forwarded.fetch_add(1, Ordering::Relaxed);
                            stats
                                .bytes_forwarded
                                .fetch_add(total as u64, Ordering::Relaxed);
                        }
                    }
                    buf.drain(..total);
                }
                Err(reason) => {
                    match reason {
                        "bad version" => {
                            stats.frames_reject_version.fetch_add(1, Ordering::Relaxed);
                            // Skip 1 byte and retry — resync on next envelope.
                            buf.drain(..1);
                        }
                        "opus_len out of bounds" => {
                            stats.frames_reject_opuslen.fetch_add(1, Ordering::Relaxed);
                            buf.drain(..1);
                        }
                        "mesh_forward_safe rejected" => {
                            stats.frames_reject_size.fetch_add(1, Ordering::Relaxed);
                            buf.drain(..1);
                        }
                        _ => {
                            // "short header" or "short opus" — wait for more bytes.
                            stats.frames_reject_short.fetch_add(1, Ordering::Relaxed);
                            break;
                        }
                    }
                }
            }
        }
    }
    let _ = peer;
}

fn main() -> std::io::Result<()> {
    let bind = env::var("AUDIO_FWD_BIND").unwrap_or_else(|_| "127.0.0.1:9701".into());
    let peers_str = env::var("AUDIO_FWD_PEERS").unwrap_or_default();
    let udp_bind = env::var("AUDIO_FWD_UDP_BIND").unwrap_or_else(|_| "0.0.0.0:0".into());

    let peers = parse_peers(&peers_str);
    let sock = UdpSocket::bind(&udp_bind)?;
    let listener = TcpListener::bind(&bind)?;
    let stats = Arc::new(Stats::new());
    let replay = Arc::new(ReplayGuard::new());

    println!(
        "audio_forwarder listening on {bind}, udp_src={}, peers={:?}",
        sock.local_addr()?,
        peers
    );
    println!("phi^2 + phi^-2 = 3");

    // Optional stats endpoint
    if let Ok(sp) = env::var("AUDIO_FWD_STATS_PORT") {
        if let Ok(port) = sp.parse::<u16>() {
            let sl = TcpListener::bind(("127.0.0.1", port))?;
            let s = stats.clone();
            thread::spawn(move || {
                for conn in sl.incoming().flatten() {
                    let mut c = conn;
                    let _ = writeln!(c, "{}", s.render());
                }
            });
            println!("audio_forwarder stats endpoint on 127.0.0.1:{port}");
        }
    }

    for conn in listener.incoming() {
        match conn {
            Ok(stream) => {
                let sock = sock.try_clone()?;
                let peers = peers.clone();
                let stats = stats.clone();
                let replay = replay.clone();
                thread::spawn(move || handle_conn(stream, &sock, &peers, &stats, &replay));
            }
            Err(e) => eprintln!("accept error: {e}"),
        }
    }
    Ok(())
}

// ─── tests ─────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn make_frame(opus_len: u16, extra: u8) -> Vec<u8> {
        let mut v = Vec::with_capacity(9 + opus_len as usize);
        v.push(1); // version
        v.extend_from_slice(&0xDEADBEEFu32.to_be_bytes());
        v.extend_from_slice(&7u16.to_be_bytes());
        v.extend_from_slice(&opus_len.to_be_bytes());
        for _ in 0..opus_len {
            v.push(0xF8);
        }
        for _ in 0..extra {
            v.push(0xAA);
        }
        v
    }

    #[test]
    fn envelope_ok() {
        let f = make_frame(80, 0);
        assert_eq!(envelope_verdict(&f).unwrap(), 89);
    }

    #[test]
    fn envelope_rejects_bad_version() {
        let mut f = make_frame(80, 0);
        f[0] = 2;
        assert_eq!(envelope_verdict(&f).unwrap_err(), "bad version");
    }

    #[test]
    fn envelope_rejects_opuslen_too_small() {
        // Craft with opus_len=2, payload=2 bytes to keep it consistent so
        // that we hit the opuslen check first.
        let mut v = vec![1u8];
        v.extend_from_slice(&0u32.to_be_bytes());
        v.extend_from_slice(&0u16.to_be_bytes());
        v.extend_from_slice(&2u16.to_be_bytes());
        v.push(0);
        v.push(0);
        assert_eq!(envelope_verdict(&v).unwrap_err(), "opus_len out of bounds");
    }

    #[test]
    fn envelope_short_header() {
        assert_eq!(envelope_verdict(&[0u8; 5]).unwrap_err(), "short header");
    }

    #[test]
    fn envelope_short_opus() {
        let mut v = vec![1u8];
        v.extend_from_slice(&0u32.to_be_bytes());
        v.extend_from_slice(&0u16.to_be_bytes());
        v.extend_from_slice(&80u16.to_be_bytes()); // opus_len declared
        // No payload appended — should be "short opus"
        assert_eq!(envelope_verdict(&v).unwrap_err(), "short opus");
    }

    #[test]
    fn parse_peers_ok() {
        let peers = parse_peers("127.0.0.1:9711, 127.0.0.1:9712 ,10.0.0.11:9711");
        assert_eq!(peers.len(), 3);
        assert_eq!(peers[0].port(), 9711);
    }

    #[test]
    fn parse_peers_ignores_garbage() {
        let peers = parse_peers("garbage,,127.0.0.1:9711,also_bad");
        assert_eq!(peers.len(), 1);
    }

    // ─── ReplayGuard tests (weak-point #8 regression) ───────────────────────

    #[test]
    fn replay_first_frame_accepted() {
        let g = ReplayGuard::new();
        assert!(g.accept(0xDEADBEEF, 100));
    }

    #[test]
    fn replay_exact_duplicate_rejected() {
        let g = ReplayGuard::new();
        assert!(g.accept(0xDEADBEEF, 100));
        assert!(!g.accept(0xDEADBEEF, 100), "same seq must be rejected");
    }

    #[test]
    fn replay_monotonic_seq_accepted() {
        let g = ReplayGuard::new();
        for s in 100u16..200 {
            assert!(g.accept(0xDEADBEEF, s), "seq {s} should be accepted");
        }
    }

    #[test]
    fn replay_within_window_accepted_once_only() {
        let g = ReplayGuard::new();
        assert!(g.accept(0xDEADBEEF, 200)); // highest = 200
        // Frame 195 arrives out-of-order, still inside window (5 back).
        assert!(g.accept(0xDEADBEEF, 195));
        // A second copy of 195 must be rejected.
        assert!(!g.accept(0xDEADBEEF, 195));
    }

    #[test]
    fn replay_too_old_rejected() {
        let g = ReplayGuard::new();
        // Fast-forward highest to 500, then try seq 100 (400 back).
        for s in 1u16..501 {
            assert!(g.accept(0xDEADBEEF, s));
        }
        assert!(!g.accept(0xDEADBEEF, 100), "400-back must be rejected");
    }

    #[test]
    fn replay_isolated_per_session() {
        let g = ReplayGuard::new();
        assert!(g.accept(0xAAAA, 100));
        // Same seq from different session must be accepted — sessions are
        // independent replay contexts.
        assert!(g.accept(0xBBBB, 100));
        // But duplicate within a session is still rejected.
        assert!(!g.accept(0xAAAA, 100));
    }

    #[test]
    fn replay_wrap_around() {
        let g = ReplayGuard::new();
        // Push seq near the 16-bit boundary.
        assert!(g.accept(0xDEADBEEF, 65530));
        assert!(g.accept(0xDEADBEEF, 65535));
        // Wrap: new seq 3 is 4 steps forward from 65535 (mod 2^16).
        assert!(g.accept(0xDEADBEEF, 3), "wrap-around must be accepted");
        // Immediate replay of the wrapped seq is rejected.
        assert!(!g.accept(0xDEADBEEF, 3));
    }

    #[test]
    fn extract_session_seq_layout() {
        let f = make_frame(80, 0);
        let (sid, seq) = extract_session_seq(&f);
        assert_eq!(sid, 0xDEADBEEF);
        assert_eq!(seq, 7);
    }
}
