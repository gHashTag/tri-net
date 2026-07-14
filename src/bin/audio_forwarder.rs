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

use std::env;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

struct Stats {
    frames_in: AtomicU64,
    frames_ok: AtomicU64,
    frames_reject_version: AtomicU64,
    frames_reject_opuslen: AtomicU64,
    frames_reject_size: AtomicU64,
    frames_reject_short: AtomicU64,
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
            frames_forwarded: AtomicU64::new(0),
            bytes_forwarded: AtomicU64::new(0),
        }
    }
    fn render(&self) -> String {
        format!(
            "frames_in={} frames_ok={} reject_version={} reject_opuslen={} reject_size={} reject_short={} forwarded={} bytes_forwarded={}",
            self.frames_in.load(Ordering::Relaxed),
            self.frames_ok.load(Ordering::Relaxed),
            self.frames_reject_version.load(Ordering::Relaxed),
            self.frames_reject_opuslen.load(Ordering::Relaxed),
            self.frames_reject_size.load(Ordering::Relaxed),
            self.frames_reject_short.load(Ordering::Relaxed),
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

fn handle_conn(mut stream: TcpStream, sock: &UdpSocket, peers: &[SocketAddr], stats: &Stats) {
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
                thread::spawn(move || handle_conn(stream, &sock, &peers, &stats));
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
}
