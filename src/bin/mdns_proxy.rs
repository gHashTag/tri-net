// mdns_proxy -- RFC 8766 style Discovery Proxy overlay runtime.
//
// This binary is a THIN WRAPPER (AGENTS.md: bins hold only socket + dispatch
// glue). All spec-verifiable logic -- envelope constants, predicates, bounded
// framing bounds, and qtype routing -- is sourced from the generated module
// gen/rust/mdns_proxy.rs, which is produced by t27c from specs/mdns_proxy.t27.
// This file adds ONLY: struct serialization, TCP framing I/O, the two-process
// dispatch loop, and CLI glue.
//
// Non-claims (see specs/mdns_proxy.t27 for the authoritative list):
//   * NOT a complete RFC 8766 implementation: no rate limiting (RFC 8766 s6),
//     no administratively-prohibited-name filtering (s7), no DNSSEC/DNS-Push.
//   * NOT DoS-hardened beyond bounded framing.
//   * NOT confidentiality-protected: the overlay is plaintext TCP. Wrap in the
//     mesh AEAD (src/crypto.rs) before any adversarial channel.
//
// phi^2 + phi^-2 = 3

use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream};

// Spec-verifiable logic, generated from specs/mdns_proxy.t27 by t27c.
#[path = "../../gen/rust/mdns_proxy.rs"]
mod proxy;

use proxy::{
    query_header_byte, qname_len_valid, proxy_version_valid, reply_header_byte,
    route_for_qtype, status_valid, MAX_FRAME_LEN, MAX_QNAME_LEN,
    QUERY_HEADER_LEN, REPLY_HEADER_LEN, ROUTE_FORWARD, ROUTE_LOCAL, STATUS_OK,
    STATUS_REFUSED,
};

// A qname string is valid iff non-empty and within the generated
// MAX_QNAME_LEN ceiling; the length bound itself is checked by the generated
// predicate so the wire rule lives in exactly one place (the spec).
fn qname_valid(name: &str) -> bool {
    if name.is_empty() || name.len() > MAX_QNAME_LEN as usize {
        return false;
    }
    qname_len_valid(name.len() as u16)
}

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
    BadStatus,
    BadUtf8,
}

// Serialize a query using the generated per-byte header layout, so the header
// wire order is defined once in the spec (query_header_byte) and never drifts.
pub fn wrap_query(q: &ProxyQuery) -> Option<Vec<u8>> {
    if !qname_valid(&q.qname) {
        return None;
    }
    let qlen = q.qname.len() as u8;
    let hdr = QUERY_HEADER_LEN as usize;
    let mut out = Vec::with_capacity(hdr + q.qname.len());
    for idx in 0..QUERY_HEADER_LEN {
        out.push(query_header_byte(q.txid, q.qtype, qlen, idx));
    }
    out.extend_from_slice(q.qname.as_bytes());
    Some(out)
}

pub fn unwrap_query(wire: &[u8]) -> Result<ProxyQuery, UnwrapError> {
    let hdr = QUERY_HEADER_LEN as usize;
    if wire.len() < hdr {
        return Err(UnwrapError::TooShort);
    }
    if !proxy_version_valid(wire[0]) {
        return Err(UnwrapError::BadVersion);
    }
    let txid = u16::from_be_bytes([wire[1], wire[2]]);
    let qtype = u16::from_be_bytes([wire[3], wire[4]]);
    let qname_len = wire[5] as usize;
    if !qname_len_valid(qname_len as u16) {
        return Err(UnwrapError::BadQnameLen);
    }
    if wire.len() < hdr + qname_len {
        return Err(UnwrapError::TooShort);
    }
    let qname = std::str::from_utf8(&wire[hdr..hdr + qname_len])
        .map_err(|_| UnwrapError::BadUtf8)?
        .to_string();
    Ok(ProxyQuery { txid, qtype, qname })
}

pub fn wrap_reply(r: &ProxyReply) -> Option<Vec<u8>> {
    if !status_valid(r.status) || r.payload.len() > u16::MAX as usize {
        return None;
    }
    let hdr = REPLY_HEADER_LEN as usize;
    let plen = r.payload.len() as u16;
    let mut out = Vec::with_capacity(hdr + r.payload.len());
    for idx in 0..REPLY_HEADER_LEN {
        out.push(reply_header_byte(r.txid, r.status, plen, idx));
    }
    out.extend_from_slice(&r.payload);
    Some(out)
}

pub fn unwrap_reply(wire: &[u8]) -> Result<ProxyReply, UnwrapError> {
    let hdr = REPLY_HEADER_LEN as usize;
    if wire.len() < hdr {
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
    if wire.len() < hdr + payload_len {
        return Err(UnwrapError::TooShort);
    }
    let payload = wire[hdr..hdr + payload_len].to_vec();
    Ok(ProxyReply { txid, status, payload })
}

// Bounded framing: a 2-byte big-endian length prefix, capped at the generated
// MAX_FRAME_LEN. Anything larger is treated as hostile.
pub fn read_framed(stream: &mut impl Read) -> io::Result<Vec<u8>> {
    let mut len_buf = [0u8; 2];
    stream.read_exact(&mut len_buf)?;
    let len = u16::from_be_bytes(len_buf);
    if len > MAX_FRAME_LEN {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "frame too large"));
    }
    let mut buf = vec![0u8; len as usize];
    stream.read_exact(&mut buf)?;
    Ok(buf)
}

pub fn write_framed(stream: &mut impl Write, payload: &[u8]) -> io::Result<()> {
    if payload.len() > MAX_FRAME_LEN as usize {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "frame too large"));
    }
    stream.write_all(&(payload.len() as u16).to_be_bytes())?;
    stream.write_all(payload)?;
    Ok(())
}

// Dispatch one query to a reply using the generated routing table. LOCAL
// (PTR/SRV/TXT) is answered from the proxy; FORWARD (A/ANY) returns a forward
// marker (a real mesh relays here); everything else is REFUSED.
fn answer(q: &ProxyQuery) -> ProxyReply {
    let route = route_for_qtype(q.qtype);
    if route == ROUTE_LOCAL {
        let mut payload = b"LOCAL:".to_vec();
        payload.extend_from_slice(q.qname.as_bytes());
        ProxyReply { txid: q.txid, status: STATUS_OK, payload }
    } else if route == ROUTE_FORWARD {
        ProxyReply { txid: q.txid, status: STATUS_OK, payload: b"FORWARD".to_vec() }
    } else {
        ProxyReply { txid: q.txid, status: STATUS_REFUSED, payload: Vec::new() }
    }
}

fn serve(addr: &str) -> io::Result<()> {
    let listener = TcpListener::bind(addr)?;
    eprintln!("mdns_proxy: serving on {addr}");
    for stream in listener.incoming() {
        let mut stream = stream?;
        let wire = match read_framed(&mut stream) {
            Ok(w) => w,
            Err(_) => continue,
        };
        let reply = match unwrap_query(&wire) {
            Ok(q) => answer(&q),
            Err(_) => ProxyReply { txid: 0, status: STATUS_REFUSED, payload: Vec::new() },
        };
        if let Some(out) = wrap_reply(&reply) {
            let _ = write_framed(&mut stream, &out);
        }
    }
    Ok(())
}

fn query(addr: &str, qtype: u16, qname: &str) -> io::Result<()> {
    let mut stream = TcpStream::connect(addr)?;
    let q = ProxyQuery { txid: 0xBEEF, qtype, qname: qname.to_string() };
    let wire = wrap_query(&q)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid query"))?;
    write_framed(&mut stream, &wire)?;
    let reply_wire = read_framed(&mut stream)?;
    let reply = unwrap_reply(&reply_wire)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("{e:?}")))?;
    let payload = String::from_utf8_lossy(&reply.payload);
    println!("status={} payload={payload}", reply.status);
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let rc = match args.get(1).map(String::as_str) {
        Some("--serve") if args.len() == 3 => serve(&args[2]).map(|_| 0).unwrap_or(1),
        Some("--query") if args.len() == 5 => {
            let qtype: u16 = args[3].parse().unwrap_or(0);
            query(&args[2], qtype, &args[4]).map(|_| 0).unwrap_or(1)
        }
        _ => {
            eprintln!("usage: mdns_proxy --serve <addr> | --query <addr> <qtype> <qname>");
            2
        }
    };
    std::process::exit(rc);
}

#[cfg(test)]
mod tests {
    use super::*;
    use proxy::{QTYPE_A, QTYPE_ANY, QTYPE_PTR, QTYPE_SRV, QTYPE_TXT, ROUTE_DROP};

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
        assert!(qname_valid(&"a".repeat(255)));
        assert!(!qname_valid(&"a".repeat(256)));
    }

    #[test]
    fn query_wrap_unwrap_roundtrip() {
        let q = ProxyQuery { txid: 0xBEEF, qtype: 12, qname: "_trinet-admin._tcp.local".to_string() };
        let wire = wrap_query(&q).expect("wrap ok");
        assert_eq!(unwrap_query(&wire).expect("unwrap ok"), q);
    }

    #[test]
    fn reply_wrap_unwrap_roundtrip() {
        let r = ProxyReply { txid: 0xBEEF, status: 0, payload: vec![1, 2, 3, 4, 5] };
        let wire = wrap_reply(&r).expect("wrap ok");
        assert_eq!(unwrap_reply(&wire).expect("unwrap ok"), r);
    }

    #[test]
    fn reply_wrap_rejects_bad_status() {
        let r = ProxyReply { txid: 0, status: 42, payload: vec![] };
        assert!(wrap_reply(&r).is_none());
    }

    #[test]
    fn query_wrap_rejects_empty_qname() {
        let q = ProxyQuery { txid: 0, qtype: 12, qname: String::new() };
        assert!(wrap_query(&q).is_none());
    }

    #[test]
    fn query_wrap_rejects_too_long_qname() {
        let q = ProxyQuery { txid: 0, qtype: 12, qname: "a".repeat(256) };
        assert!(wrap_query(&q).is_none());
    }

    #[test]
    fn query_unwrap_rejects_bad_version() {
        assert_eq!(unwrap_query(&[2u8, 0, 0, 0, 12, 1, b'x']), Err(UnwrapError::BadVersion));
    }

    #[test]
    fn query_unwrap_rejects_zero_qname_len() {
        assert_eq!(unwrap_query(&[1u8, 0, 0, 0, 12, 0]), Err(UnwrapError::BadQnameLen));
    }

    #[test]
    fn query_unwrap_rejects_short() {
        assert_eq!(unwrap_query(&[]), Err(UnwrapError::TooShort));
        assert_eq!(unwrap_query(&[1, 0, 0, 0, 12]), Err(UnwrapError::TooShort));
    }

    #[test]
    fn query_unwrap_rejects_truncated_qname() {
        assert_eq!(unwrap_query(&[1u8, 0, 0, 0, 12, 10, b'a', b'b', b'c']), Err(UnwrapError::TooShort));
    }

    #[test]
    fn reply_unwrap_rejects_bad_status() {
        assert_eq!(unwrap_reply(&[1u8, 0, 0, 42, 0, 0]), Err(UnwrapError::BadStatus));
    }

    #[test]
    fn framed_roundtrip_over_memory() {
        let payload = b"framed-payload".to_vec();
        let mut buf: Vec<u8> = Vec::new();
        write_framed(&mut buf, &payload).unwrap();
        let mut cursor = std::io::Cursor::new(buf);
        assert_eq!(read_framed(&mut cursor).unwrap(), payload);
    }

    #[test]
    fn answer_routes_via_generated_table() {
        assert_eq!(route_for_qtype(QTYPE_PTR), ROUTE_LOCAL);
        assert_eq!(route_for_qtype(QTYPE_SRV), ROUTE_LOCAL);
        assert_eq!(route_for_qtype(QTYPE_TXT), ROUTE_LOCAL);
        assert_eq!(route_for_qtype(QTYPE_A), ROUTE_FORWARD);
        assert_eq!(route_for_qtype(QTYPE_ANY), ROUTE_FORWARD);
        assert_eq!(route_for_qtype(9999), ROUTE_DROP);

        let local = answer(&ProxyQuery { txid: 1, qtype: QTYPE_PTR, qname: "x.local".to_string() });
        assert_eq!(local.status, STATUS_OK);
        assert!(local.payload.starts_with(b"LOCAL:"));

        let fwd = answer(&ProxyQuery { txid: 1, qtype: QTYPE_A, qname: "x.local".to_string() });
        assert_eq!(fwd.status, STATUS_OK);
        assert_eq!(fwd.payload, b"FORWARD");

        let drop = answer(&ProxyQuery { txid: 1, qtype: 9999, qname: "x.local".to_string() });
        assert_eq!(drop.status, STATUS_REFUSED);
        assert!(drop.payload.is_empty());
    }
}
