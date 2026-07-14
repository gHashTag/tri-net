//! admin-httpd binary — iPhone-facing admin dashboard + PTT surface for
//! Tri-Net P203 Mini nodes. Standalone (does not depend on crate root):
//! includes generated t27 modules directly via `#[path]` so this bin builds
//! even while other modules under gen/rust/ are still under repair.
//!
//! phi^2 + phi^-2 = 3

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

// Bring the generated primitives into scope. These modules contain ONLY
// what came out of `t27c gen-rust`; every function in them mirrors an
// assertion-covered spec function.
#[path = "../../gen/rust/ptt_frame.rs"]
#[allow(dead_code, unused_parens, clippy::all)]
mod ptt_frame_gen;

#[path = "../../gen/rust/ws_accept.rs"]
#[allow(dead_code, unused_parens, clippy::all)]
mod ws_accept_gen;

#[path = "../../gen/rust/admin_status.rs"]
#[allow(dead_code, unused_parens, clippy::all)]
mod admin_status_gen;

const BUILD_TAG: &str = "admin_httpd v0.1 skeleton (-sim)";

// ─── SHA-1 driver (composes ws_accept_gen primitives) ───────────────────────

fn sha1(msg: &[u8]) -> [u8; 20] {
    let bit_len = (msg.len() as u64).wrapping_mul(8);
    let mut padded = msg.to_vec();
    padded.push(0x80);
    while padded.len() % 64 != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&bit_len.to_be_bytes());

    let mut h0 = ws_accept_gen::H0_INIT;
    let mut h1 = ws_accept_gen::H1_INIT;
    let mut h2 = ws_accept_gen::H2_INIT;
    let mut h3 = ws_accept_gen::H3_INIT;
    let mut h4 = ws_accept_gen::H4_INIT;

    for chunk in padded.chunks(64) {
        let mut w = [0u32; 80];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                chunk[i * 4],
                chunk[i * 4 + 1],
                chunk[i * 4 + 2],
                chunk[i * 4 + 3],
            ]);
        }
        for i in 16..80 {
            w[i] = ws_accept_gen::schedule_extend(w[i - 3], w[i - 8], w[i - 14], w[i - 16]);
        }

        // Runtime combines summands with wrapping_add — SHA-1 is mod 2^32.
        let (mut a, mut b, mut c, mut d, mut e) = (h0, h1, h2, h3, h4);
        for i in 0..80u8 {
            let t = ws_accept_gen::step_a_term(a)
                .wrapping_add(ws_accept_gen::step_f_term(i, b, c, d))
                .wrapping_add(e)
                .wrapping_add(ws_accept_gen::round_k(i))
                .wrapping_add(w[i as usize]);
            e = d;
            d = c;
            c = ws_accept_gen::rotl32(b, 30);
            b = a;
            a = t;
        }
        h0 = h0.wrapping_add(a);
        h1 = h1.wrapping_add(b);
        h2 = h2.wrapping_add(c);
        h3 = h3.wrapping_add(d);
        h4 = h4.wrapping_add(e);
    }

    let mut out = [0u8; 20];
    for (i, w) in [h0, h1, h2, h3, h4].iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&w.to_be_bytes());
    }
    out
}

// ─── base64 (composes ws_accept_gen::b64_sextet + b64_char) ─────────────────

fn b64_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    let mut i = 0;
    while i + 3 <= bytes.len() {
        let (a, b, c) = (bytes[i], bytes[i + 1], bytes[i + 2]);
        for k in 0..4u8 {
            out.push(ws_accept_gen::b64_char(ws_accept_gen::b64_sextet(a, b, c, k)) as char);
        }
        i += 3;
    }
    let rem = bytes.len() - i;
    if rem == 1 {
        let a = bytes[i];
        out.push(ws_accept_gen::b64_char(ws_accept_gen::b64_sextet(a, 0, 0, 0)) as char);
        out.push(ws_accept_gen::b64_char(ws_accept_gen::b64_sextet(a, 0, 0, 1)) as char);
        out.push('=');
        out.push('=');
    } else if rem == 2 {
        let (a, b) = (bytes[i], bytes[i + 1]);
        out.push(ws_accept_gen::b64_char(ws_accept_gen::b64_sextet(a, b, 0, 0)) as char);
        out.push(ws_accept_gen::b64_char(ws_accept_gen::b64_sextet(a, b, 0, 1)) as char);
        out.push(ws_accept_gen::b64_char(ws_accept_gen::b64_sextet(a, b, 0, 2)) as char);
        out.push('=');
    }
    out
}

fn ws_accept_key(client_key: &str) -> Option<String> {
    if !ws_accept_gen::key_length_valid(client_key.len()) {
        return None;
    }
    const MAGIC: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    let combined = format!("{client_key}{MAGIC}");
    Some(b64_encode(&sha1(combined.as_bytes())))
}

// ─── HTTP framing (byte I/O only) ────────────────────────────────────────────

struct Req {
    method: String,
    path: String,
    headers: Vec<(String, String)>,
}
impl Req {
    fn header(&self, name: &str) -> Option<&str> {
        let want = name.to_ascii_lowercase();
        self.headers
            .iter()
            .find(|(k, _)| k.to_ascii_lowercase() == want)
            .map(|(_, v)| v.as_str())
    }
}

fn read_request(stream: &mut TcpStream) -> std::io::Result<Req> {
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    let mut buf = [0u8; 4096];
    let mut acc: Vec<u8> = Vec::new();
    loop {
        let n = stream.read(&mut buf)?;
        if n == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "closed before headers",
            ));
        }
        acc.extend_from_slice(&buf[..n]);
        if acc.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
        if acc.len() > 16 * 1024 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "headers too large",
            ));
        }
    }
    let end = acc.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
    let head = std::str::from_utf8(&acc[..end])
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "non-utf8"))?;
    let mut lines = head.split("\r\n");
    let first = lines.next().unwrap_or("");
    let mut parts = first.split_whitespace();
    let method = parts.next().unwrap_or("").to_string();
    let path = parts.next().unwrap_or("/").to_string();
    let mut headers = Vec::new();
    for line in lines {
        if let Some(idx) = line.find(':') {
            headers.push((
                line[..idx].trim().to_string(),
                line[idx + 1..].trim().to_string(),
            ));
        }
    }
    Ok(Req { method, path, headers })
}

fn write_response(
    stream: &mut TcpStream,
    code: u16,
    ct: &str,
    body: &[u8],
) -> std::io::Result<()> {
    let reason = match code {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        _ => "Response",
    };
    let hdr = format!(
        "HTTP/1.1 {code} {reason}\r\nContent-Type: {ct}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(hdr.as_bytes())?;
    stream.write_all(body)
}

fn path_is_safe(path: &str) -> bool {
    let bytes = path.as_bytes();
    if bytes.is_empty() { return false; }
    for &b in bytes {
        if !admin_status_gen::path_byte_legal(b) {
            return false;
        }
    }
    for w in bytes.windows(2) {
        if admin_status_gen::is_dot_dot(w[0], w[1]) {
            return false;
        }
    }
    true
}

fn build_status_json(node_id: u16, started: Instant, attest: u8) -> String {
    let secs_full = started.elapsed().as_secs();
    let uptime = admin_status_gen::uptime_clamp_u32(
        ((secs_full >> 32) & 0xFFFFFFFF) as u32,
        (secs_full & 0xFFFFFFFF) as u32,
    );
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let attest_valid = admin_status_gen::attest_valid(attest);
    let write_ok = admin_status_gen::write_allowed(attest);
    let chip_full = admin_status_gen::chip_attested(attest);
    let id_valid = admin_status_gen::node_id_valid(node_id);
    format!(
        r#"{{"type":"status","node_id":{node_id},"node_id_valid":{id_valid},"uptime_s":{uptime},"unix_time":{now},"build":"{BUILD_TAG}","attest_state":{attest},"attest_valid":{attest_valid},"write_allowed":{write_ok},"chip_attested":{chip_full},"listen":"0.0.0.0:5000","hello_ms":300,"etx_window":3}}"#
    )
}

// ─── WebSocket frame I/O ─────────────────────────────────────────────────────

fn ws_send_text(stream: &mut TcpStream, text: &str) -> std::io::Result<()> {
    let payload = text.as_bytes();
    let mut frame = Vec::with_capacity(payload.len() + 10);
    frame.push(0x81);
    if payload.len() < 126 {
        frame.push(payload.len() as u8);
    } else if payload.len() < 65536 {
        frame.push(126);
        frame.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    } else {
        frame.push(127);
        frame.extend_from_slice(&(payload.len() as u64).to_be_bytes());
    }
    frame.extend_from_slice(payload);
    stream.write_all(&frame)
}

fn ws_recv_text(stream: &mut TcpStream) -> std::io::Result<Option<String>> {
    let mut hdr = [0u8; 2];
    stream.read_exact(&mut hdr)?;
    let opcode = hdr[0] & 0x0f;
    let masked = hdr[1] & 0x80 != 0;
    let mut len = (hdr[1] & 0x7f) as u64;
    if len == 126 {
        let mut b = [0u8; 2];
        stream.read_exact(&mut b)?;
        len = u16::from_be_bytes(b) as u64;
    } else if len == 127 {
        let mut b = [0u8; 8];
        stream.read_exact(&mut b)?;
        len = u64::from_be_bytes(b);
    }
    let mut mask = [0u8; 4];
    if masked {
        stream.read_exact(&mut mask)?;
    }
    if len > 1 << 20 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "oversized",
        ));
    }
    let mut payload = vec![0u8; len as usize];
    stream.read_exact(&mut payload)?;
    if masked {
        for (i, b) in payload.iter_mut().enumerate() {
            *b ^= mask[i & 3];
        }
    }
    match opcode {
        0x1 => Ok(Some(String::from_utf8_lossy(&payload).into_owned())),
        0x8 => Err(std::io::Error::new(
            std::io::ErrorKind::ConnectionAborted,
            "close",
        )),
        _ => Ok(None),
    }
}

// ─── Connection dispatch ─────────────────────────────────────────────────────

fn handle_conn(
    mut stream: TcpStream,
    webroot: &Path,
    node_id: u16,
    started: Instant,
    cid: u64,
) -> std::io::Result<()> {
    let req = read_request(&mut stream)?;
    eprintln!("conn#{cid} {} {}", req.method, req.path);
    if req.method != "GET" {
        return write_response(&mut stream, 405, "text/plain", b"method not allowed");
    }
    if req.path == "/ws" {
        let upgrade = req.header("upgrade").unwrap_or("").to_ascii_lowercase();
        let key = req.header("sec-websocket-key").unwrap_or("").to_string();
        if !upgrade.contains("websocket") {
            return write_response(&mut stream, 400, "text/plain", b"expected websocket");
        }
        let accept = match ws_accept_key(&key) {
            Some(a) => a,
            None => return write_response(&mut stream, 400, "text/plain", b"bad ws key"),
        };
        let hdr = format!(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
        );
        stream.write_all(hdr.as_bytes())?;
        eprintln!("conn#{cid} ws upgraded");
        return ws_loop(stream, node_id, started, cid);
    }
    if req.path == "/api/status" {
        let body = build_status_json(node_id, started, admin_status_gen::ATTEST_ED25519_SIM);
        return write_response(&mut stream, 200, "application/json", body.as_bytes());
    }
    let rel = if req.path == "/" { "/index.html" } else { req.path.as_str() };
    if !path_is_safe(rel) {
        return write_response(&mut stream, 403, "text/plain", b"forbidden");
    }
    let full = webroot.join(rel.trim_start_matches('/'));
    if !full.starts_with(webroot) {
        return write_response(&mut stream, 403, "text/plain", b"forbidden");
    }
    match std::fs::read(&full) {
        Ok(body) => {
            let ct = match full.extension().and_then(|s| s.to_str()) {
                Some("html") => "text/html; charset=utf-8",
                Some("json") => "application/json",
                Some("js") => "application/javascript",
                Some("css") => "text/css",
                _ => "application/octet-stream",
            };
            write_response(&mut stream, 200, ct, &body)
        }
        Err(_) => write_response(&mut stream, 404, "text/plain", b"not found"),
    }
}

fn ws_loop(
    mut stream: TcpStream,
    node_id: u16,
    started: Instant,
    cid: u64,
) -> std::io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_millis(250)))?;
    let mut last_push = Instant::now() - Duration::from_secs(2);
    let mut ptt_state: u8 = 0;
    loop {
        if last_push.elapsed() >= Duration::from_secs(1) {
            let s = build_status_json(node_id, started, admin_status_gen::ATTEST_ED25519_SIM);
            if ws_send_text(&mut stream, &s).is_err() {
                return Ok(());
            }
            let _ = ws_send_text(&mut stream, r#"{"type":"neighbors","list":[]}"#);
            last_push = Instant::now();
        }
        match ws_recv_text(&mut stream) {
            Ok(Some(msg)) => {
                eprintln!("conn#{cid} ws rx: {}", &msg[..msg.len().min(120)]);
                if msg.contains("\"type\":\"ptt\"") {
                    let action = if msg.contains("\"action\":\"start\"") {
                        ptt_frame_gen::ACT_START
                    } else if msg.contains("\"action\":\"stop\"") {
                        ptt_frame_gen::ACT_STOP
                    } else {
                        ptt_frame_gen::ACT_HEARTBEAT
                    };
                    if ptt_frame_gen::transition_valid(ptt_state, action) {
                        ptt_state = ptt_frame_gen::next_state(ptt_state, action);
                        let state_name = if ptt_state == 1 { "talking" } else { "idle" };
                        let ack = format!(
                            r#"{{"type":"ptt-ack","state":"{state_name}","accepted":true}}"#
                        );
                        let _ = ws_send_text(&mut stream, &ack);
                    } else {
                        let ack = r#"{"type":"ptt-ack","state":"unchanged","accepted":false,"reason":"invalid transition"}"#;
                        let _ = ws_send_text(&mut stream, ack);
                    }
                }
            }
            Ok(None) => {}
            Err(e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut => {}
            Err(_) => return Ok(()),
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let addr = args.get(1).map(String::as_str).unwrap_or("127.0.0.1:8080");
    let webroot = args
        .get(2)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("webui/public"));
    let node_id: u16 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(11);

    let started = Instant::now();
    let listener = match TcpListener::bind(addr) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("admin-httpd: bind {addr}: {e}");
            std::process::exit(2);
        }
    };
    eprintln!("admin_httpd listening on {addr}, webroot={}", webroot.display());
    eprintln!("node_id={node_id} build={BUILD_TAG}");
    eprintln!("phi^2 + phi^-2 = 3");
    static CONN_ID: AtomicU64 = AtomicU64::new(0);
    for stream in listener.incoming() {
        let stream = match stream {
            Ok(s) => s,
            Err(_) => continue,
        };
        let webroot = webroot.clone();
        let cid = CONN_ID.fetch_add(1, Ordering::Relaxed);
        thread::spawn(move || {
            if let Err(e) = handle_conn(stream, &webroot, node_id, started, cid) {
                eprintln!("conn#{cid}: {e}");
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha1_rfc3174_abc() {
        let d = sha1(b"abc");
        let hex: String = d.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, "a9993e364706816aba3e25717850c26c9cd0d89d");
    }

    #[test]
    fn sha1_rfc3174_empty() {
        let d = sha1(b"");
        let hex: String = d.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, "da39a3ee5e6b4b0d3255bfef95601890afd80709");
    }

    #[test]
    fn sha1_fox() {
        let d = sha1(b"The quick brown fox jumps over the lazy dog");
        let hex: String = d.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12");
    }

    #[test]
    fn b64_rfc4648_vectors() {
        assert_eq!(b64_encode(b""), "");
        assert_eq!(b64_encode(b"f"), "Zg==");
        assert_eq!(b64_encode(b"fo"), "Zm8=");
        assert_eq!(b64_encode(b"foo"), "Zm9v");
        assert_eq!(b64_encode(b"foob"), "Zm9vYg==");
        assert_eq!(b64_encode(b"fooba"), "Zm9vYmE=");
        assert_eq!(b64_encode(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn ws_accept_rfc6455_example() {
        let key = "dGhlIHNhbXBsZSBub25jZQ==";
        assert_eq!(
            ws_accept_key(key).as_deref(),
            Some("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        );
    }

    #[test]
    fn ws_accept_rejects_short_key() {
        assert_eq!(ws_accept_key("short"), None);
    }

    #[test]
    fn path_safety_rejects_traversal() {
        assert!(path_is_safe("/index.html"));
        assert!(path_is_safe("/manifest.json"));
        assert!(!path_is_safe("/../etc/passwd"));
        assert!(!path_is_safe("/foo%00bar"));
        assert!(!path_is_safe(""));
        assert!(!path_is_safe("/../"));
    }
}
