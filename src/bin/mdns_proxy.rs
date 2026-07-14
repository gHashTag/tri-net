// mdns_proxy — W7 workstream (2026-07-14).
//
// RFC 8766 Discovery Proxy skeleton. Wraps mDNS queries into an overlay
// envelope so they can traverse the mesh across L2 segments. This file
// provides the envelope wrap/unwrap, the predicates, and unit tests.
//
// Full end-to-end runtime (two-process smoke, trios_meshd integration,
// audio_crypto envelope wrapping) is explicitly OUT OF SCOPE for this
// commit — see docs/W7_DISCOVERY_PROXY_SPEC.md §"Что откладывается на
// следующую волну".
//
// Non-claims:
//   * NOT a complete RFC 8766 implementation. §6 (Rate Limiting), §7
//     (Administratively Prohibited Names), §8 (Deployment Considerations)
//     are not touched.
//   * NOT DoS-hardened. No rate limiting.
//   * NOT confidentiality-protected. Overlay is plain TCP; replace with
//     audio_crypto envelope (W3) before adversarial deployment.
//
// phi^2 + phi^-2 = 3

use std::io::{self, Read, Write};

// ─── envelope constants ─────────────────────────────────────────────

pub const PROXY_VERSION: u8 = 1;
pub const MAX_QNAME_LEN: usize = 255;

// Query envelope: version(1) + txid(2) + qtype(2) + qname_len(1) + qname(N)
pub const QUERY_HEADER_LEN: usize = 6;

// Reply envelope: version(1) + txid(2) + status(1) + payload_len(2) + payload(N)
pub const REPLY_HEADER_LEN: usize = 6;

// ─── predicates ─────────────────────────────────────────────────────

pub fn proxy_version_valid(v: u8) -> bool {
    v == PROXY_VERSION
}

pub fn qname_valid(name: &str) -> bool {
    !name.is_empty() && name.len() <= MAX_QNAME_LEN
}

pub fn status_valid(s: u8) -> bool {
    s <= 2
}

// ─── wrap / unwrap ──────────────────────────────────────────────────

#[derive(Debug, PartialEq, Eq)]
pub struct ProxyQuery {
    pub txid: u16,
    pub qtype: u16,
    pub qname: String,
}

#[derive(Debug, PartialEq, Eq)]
pub struct ProxyReply {
    pub txid: u16,
    pub status: u8,
    pub payload: Vec<u8>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum UnwrapError {
    TooShort,
    BadVersion,
    BadQnameLen,
    BadPayloadLen,
    BadStatus,
    BadUtf8,
}

pub fn wrap_query(q: &ProxyQuery) -> Option<Vec<u8>> {
    if !qname_valid(&q.qname) {
        return None;
    }
    let mut out = Vec::with_capacity(QUERY_HEADER_LEN + q.qname.len());
    out.push(PROXY_VERSION);
    out.extend_from_slice(&q.txid.to_be_bytes());
    out.extend_from_slice(&q.qtype.to_be_bytes());
    out.push(q.qname.len() as u8);
    out.extend_from_slice(q.qname.as_bytes());
    Some(out)
}

pub fn unwrap_query(wire: &[u8]) -> Result<ProxyQuery, UnwrapError> {
    if wire.len() < QUERY_HEADER_LEN {
        return Err(UnwrapError::TooShort);
    }
    if !proxy_version_valid(wire[0]) {
        return Err(UnwrapError::BadVersion);
    }
    let txid = u16::from_be_bytes([wire[1], wire[2]]);
    let qtype = u16::from_be_bytes([wire[3], wire[4]]);
    let qname_len = wire[5] as usize;
    if qname_len == 0 {
        return Err(UnwrapError::BadQnameLen);
    }
    if wire.len() < QUERY_HEADER_LEN + qname_len {
        return Err(UnwrapError::TooShort);
    }
    let qname_bytes = &wire[QUERY_HEADER_LEN..QUERY_HEADER_LEN + qname_len];
    let qname = std::str::from_utf8(qname_bytes)
        .map_err(|_| UnwrapError::BadUtf8)?
        .to_string();
    Ok(ProxyQuery { txid, qtype, qname })
}

pub fn wrap_reply(r: &ProxyReply) -> Option<Vec<u8>> {
    if !status_valid(r.status) {
        return None;
    }
    if r.payload.len() > u16::MAX as usize {
        return None;
    }
    let mut out = Vec::with_capacity(REPLY_HEADER_LEN + r.payload.len());
    out.push(PROXY_VERSION);
    out.extend_from_slice(&r.txid.to_be_bytes());
    out.push(r.status);
    out.extend_from_slice(&(r.payload.len() as u16).to_be_bytes());
    out.extend_from_slice(&r.payload);
    Some(out)
}

pub fn unwrap_reply(wire: &[u8]) -> Result<ProxyReply, UnwrapError> {
    if wire.len() < REPLY_HEADER_LEN {
        return Err(UnwrapError::TooShort);
    }
    if !proxy_version_valid(wire[0]) {
        return Err(UnwrapError::BadVersion);
    }
    let txid = u16::from_be_bytes([wire[1], wire[2]]);
    let status = wire[3];
    if !status_valid(status) {
        return Err(UnwrapError::BadStatus);
    }
    let payload_len = u16::from_be_bytes([wire[4], wire[5]]) as usize;
    if wire.len() < REPLY_HEADER_LEN + payload_len {
        return Err(UnwrapError::TooShort);
    }
    let payload = wire[REPLY_HEADER_LEN..REPLY_HEADER_LEN + payload_len].to_vec();
    Ok(ProxyReply { txid, status, payload })
}

// ─── skeleton I/O helpers (used only by the future end-to-end runtime) ──

/// Read one length-prefixed query from a TCP stream. Length prefix is
/// 2 bytes big-endian, followed by that many bytes of envelope. Bounded
/// at 8 KiB per frame — anything larger is malicious for our workload.
pub fn read_framed(stream: &mut impl Read) -> io::Result<Vec<u8>> {
    let mut len_buf = [0u8; 2];
    stream.read_exact(&mut len_buf)?;
    let len = u16::from_be_bytes(len_buf) as usize;
    if len > 8192 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "frame too large"));
    }
    let mut buf = vec![0u8; len];
    stream.read_exact(&mut buf)?;
    Ok(buf)
}

pub fn write_framed(stream: &mut impl Write, payload: &[u8]) -> io::Result<()> {
    if payload.len() > 8192 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "frame too large"));
    }
    let len = payload.len() as u16;
    stream.write_all(&len.to_be_bytes())?;
    stream.write_all(payload)?;
    Ok(())
}

// ─── main is intentionally minimal ──────────────────────────────────
// The full binary orchestrator (bind UDP 5353, bind TCP overlay port,
// dispatch, static routing table) lands in a later workstream. For now
// the binary compiles into a no-op so the module can be linked into
// tests and future integration code.

fn main() {
    eprintln!(
        "mdns_proxy: skeleton only (W7 workstream, 2026-07-14). See \
         docs/W7_DISCOVERY_PROXY_SPEC.md for what is and is not \
         implemented in this build."
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_predicate() {
        assert!(proxy_version_valid(1));
        assert!(!proxy_version_valid(0));
        assert!(!proxy_version_valid(2));
    }

    #[test]
    fn qname_predicate() {
        assert!(!qname_valid(""));
        assert!(qname_valid("_trinet-admin._tcp.local"));
        let long = "a".repeat(255);
        assert!(qname_valid(&long));
        let too_long = "a".repeat(256);
        assert!(!qname_valid(&too_long));
    }

    #[test]
    fn query_wrap_unwrap_roundtrip() {
        let q = ProxyQuery {
            txid: 0xBEEF,
            qtype: 12, // PTR
            qname: "_trinet-admin._tcp.local".to_string(),
        };
        let wire = wrap_query(&q).expect("wrap ok");
        let back = unwrap_query(&wire).expect("unwrap ok");
        assert_eq!(back, q);
    }

    #[test]
    fn reply_wrap_unwrap_roundtrip() {
        let r = ProxyReply {
            txid: 0xBEEF,
            status: 0,
            payload: vec![1, 2, 3, 4, 5],
        };
        let wire = wrap_reply(&r).expect("wrap ok");
        let back = unwrap_reply(&wire).expect("unwrap ok");
        assert_eq!(back, r);
    }

    #[test]
    fn reply_wrap_rejects_bad_status() {
        let r = ProxyReply {
            txid: 0,
            status: 42,
            payload: vec![],
        };
        assert!(wrap_reply(&r).is_none());
    }

    #[test]
    fn query_wrap_rejects_empty_qname() {
        let q = ProxyQuery {
            txid: 0,
            qtype: 12,
            qname: String::new(),
        };
        assert!(wrap_query(&q).is_none());
    }

    #[test]
    fn query_wrap_rejects_too_long_qname() {
        let q = ProxyQuery {
            txid: 0,
            qtype: 12,
            qname: "a".repeat(256),
        };
        assert!(wrap_query(&q).is_none());
    }

    #[test]
    fn query_unwrap_rejects_bad_version() {
        let wire = vec![2u8, 0, 0, 0, 12, 1, b'x'];
        assert_eq!(unwrap_query(&wire), Err(UnwrapError::BadVersion));
    }

    #[test]
    fn query_unwrap_rejects_zero_qname_len() {
        let wire = vec![1u8, 0, 0, 0, 12, 0];
        assert_eq!(unwrap_query(&wire), Err(UnwrapError::BadQnameLen));
    }

    #[test]
    fn query_unwrap_rejects_short() {
        assert_eq!(unwrap_query(&[]), Err(UnwrapError::TooShort));
        assert_eq!(unwrap_query(&[1, 0, 0, 0, 12]), Err(UnwrapError::TooShort));
    }

    #[test]
    fn query_unwrap_rejects_truncated_qname() {
        // Declares qname_len=10 but only 3 bytes follow.
        let wire = vec![1u8, 0, 0, 0, 12, 10, b'a', b'b', b'c'];
        assert_eq!(unwrap_query(&wire), Err(UnwrapError::TooShort));
    }

    #[test]
    fn reply_unwrap_rejects_bad_status() {
        let wire = vec![1u8, 0, 0, 42 /* bad status */, 0, 0];
        assert_eq!(unwrap_reply(&wire), Err(UnwrapError::BadStatus));
    }

    #[test]
    fn framed_roundtrip_over_memory() {
        // Simulate a TCP stream with a Vec<u8> cursor.
        let payload = b"framed-payload".to_vec();
        let mut buf: Vec<u8> = Vec::new();
        write_framed(&mut buf, &payload).unwrap();
        let mut cursor = std::io::Cursor::new(buf);
        let back = read_framed(&mut cursor).unwrap();
        assert_eq!(back, payload);
    }
}
