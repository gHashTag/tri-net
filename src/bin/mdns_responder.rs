// mdns_responder.rs — E1.3 runtime for _trinet-admin._tcp.local.
//
// Discipline (t27 spec-first): the wire predicates live in specs/mdns_wire.t27
// and its gen at gen/rust/mdns_wire.rs. This binary is a byte-in / byte-out
// waiter — it never re-derives constants, it never invents flags. It reads
// mDNS queries off UDP 224.0.0.251:5353, checks whether they ask for our
// service name, and emits a unicast reply following RFC 6762 §6.7 (legacy
// unicast) and RFC 6763 §7 (SRV+TXT+PTR pack).
//
// Non-claims:
//   - We do NOT implement full mDNS conformance (no probing, no defence,
//     no known-answer suppression). We answer direct PTR/ANY queries for
//     one service name. This is enough for an iPhone Safari + Bonjour
//     client to discover the admin PWA.
//   - We do NOT flood or defend cache-flush. TTL_SHARED_S applies.
//
// Env knobs:
//   TRINET_NODE           — node id, becomes part of the instance name.
//   MDNS_BIND             — bind address (default 0.0.0.0:5353).
//   MDNS_HOSTNAME         — A-record host name (default "trinet-<id>.local").
//   MDNS_ADMIN_ADDR       — IPv4 to advertise as the admin dashboard target.
//                            Default: resolve local hostname; fallback 127.0.0.1.
//
// phi^2 + phi^-2 = 3

#[path = "../../gen/rust/mdns_wire.rs"]
mod mdns_wire;

use std::env;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, UdpSocket};
use std::time::Duration;

const MCAST_ADDR: Ipv4Addr = Ipv4Addr::new(224, 0, 0, 251);
const MCAST_PORT: u16 = 5353;

// Service instance we advertise: _trinet-admin._tcp.local, port 5000
// (matches admin_httpd default).
const SERVICE: &str = "_trinet-admin._tcp.local";
const ADMIN_PORT: u16 = 5000;

fn main() -> std::io::Result<()> {
    let node_id: u16 = env::var("TRINET_NODE")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(11);
    let bind = env::var("MDNS_BIND").unwrap_or_else(|_| "0.0.0.0:5353".into());
    let hostname = env::var("MDNS_HOSTNAME").unwrap_or_else(|_| format!("trinet-{node_id}.local"));
    let instance = format!("trinet-admin-{node_id}.{SERVICE}");

    let admin_ip: Ipv4Addr = env::var("MDNS_ADMIN_ADDR")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(Ipv4Addr::new(127, 0, 0, 1));

    let sock = UdpSocket::bind(&bind)?;
    sock.set_read_timeout(Some(Duration::from_millis(500)))?;
    // Best-effort multicast join. Errors here are non-fatal (unicast still
    // works, useful in sandboxes without multicast routes).
    if let Err(e) = sock.join_multicast_v4(&MCAST_ADDR, &Ipv4Addr::UNSPECIFIED) {
        eprintln!("mdns_responder: multicast join skipped: {e}");
    }

    println!(
        "mdns_responder listening on {bind}, node={node_id}, instance={instance}, target={hostname} @ {admin_ip}"
    );
    println!("phi^2 + phi^-2 = 3");

    let mut buf = [0u8; 1500];
    loop {
        let (n, src) = match sock.recv_from(&mut buf) {
            Ok(v) => v,
            Err(e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut =>
            {
                continue
            }
            Err(e) => {
                eprintln!("mdns_responder: recv error: {e}");
                continue;
            }
        };
        if let Some(reply) = handle_query(&buf[..n], &instance, &hostname, admin_ip, node_id) {
            let _ = sock.send_to(&reply, src);
        }
    }
}

// ─── query parsing ─────────────────────────────────────────────────────────

/// Parse the header + first question from an mDNS query. Returns
/// (txid, qname_string, qtype) if it looks like a well-formed query with at
/// least one question and no name-compression pointers in the question name
/// (compression in queries is legal but rare; we skip such packets to keep
/// the parser small).
pub fn parse_first_question(pkt: &[u8]) -> Option<(u16, String, u16)> {
    if pkt.len() < 12 {
        return None;
    }
    let txid = u16::from_be_bytes([pkt[0], pkt[1]]);
    let flags = u16::from_be_bytes([pkt[2], pkt[3]]);
    // QR=0 (query). If QR=1 it's an answer — ignore.
    if flags & 0x8000 != 0 {
        return None;
    }
    let qdcount = u16::from_be_bytes([pkt[4], pkt[5]]);
    if qdcount == 0 {
        return None;
    }

    let mut i = 12usize;
    let mut name = String::new();
    while i < pkt.len() {
        let len = pkt[i];
        if len == 0 {
            i += 1;
            break;
        }
        // Refuse compression pointers in question.
        if len & 0xC0 != 0 {
            return None;
        }
        let ll = len as usize;
        if i + 1 + ll > pkt.len() {
            return None;
        }
        if !name.is_empty() {
            name.push('.');
        }
        for &b in &pkt[i + 1..i + 1 + ll] {
            name.push(b as char);
        }
        i += 1 + ll;
    }
    if i + 4 > pkt.len() {
        return None;
    }
    let qtype = u16::from_be_bytes([pkt[i], pkt[i + 1]]);
    Some((txid, name, qtype))
}

// ─── reply assembly ────────────────────────────────────────────────────────

fn encode_name(name: &str, out: &mut Vec<u8>) {
    for label in name.split('.') {
        if label.is_empty() {
            continue;
        }
        out.push(label.len() as u8);
        out.extend_from_slice(label.as_bytes());
    }
    out.push(0); // root
}

fn build_reply(
    txid: u16,
    instance: &str,
    hostname: &str,
    admin_ip: Ipv4Addr,
    node_id: u16,
    include_ptr: bool,
) -> Vec<u8> {
    use mdns_wire::*;
    let mut pkt = Vec::with_capacity(512);

    // Header — txid, flags=FLAGS_ANNOUNCE (0x8400, QR|AA), qd=0, an=N, ns=0, ar=0.
    // N = 3 if include_ptr else 3 (SRV+TXT+A regardless).
    let ancount: u16 = if include_ptr { 4 } else { 3 };
    pkt.extend_from_slice(&txid.to_be_bytes());
    pkt.extend_from_slice(&FLAGS_ANNOUNCE.to_be_bytes());
    pkt.extend_from_slice(&0u16.to_be_bytes()); // qd
    pkt.extend_from_slice(&ancount.to_be_bytes()); // an
    pkt.extend_from_slice(&0u16.to_be_bytes()); // ns
    pkt.extend_from_slice(&0u16.to_be_bytes()); // ar

    // 1. PTR record (only if the question was for the service type).
    //    name = _trinet-admin._tcp.local, type=PTR, class=IN, ttl=TTL_SHARED_S,
    //    rdata = instance name.
    if include_ptr {
        encode_name(SERVICE, &mut pkt);
        pkt.extend_from_slice(&TYPE_PTR.to_be_bytes());
        pkt.extend_from_slice(&CLASS_IN.to_be_bytes());
        pkt.extend_from_slice(&TTL_SHARED_S.to_be_bytes());
        let mut rdata = Vec::new();
        encode_name(instance, &mut rdata);
        pkt.extend_from_slice(&(rdata.len() as u16).to_be_bytes());
        pkt.extend_from_slice(&rdata);
    }

    // 2. SRV record for the instance
    //    name = instance, type=SRV, class=IN|CACHE_FLUSH, ttl=TTL_UNIQUE_S,
    //    rdata = priority(2)+weight(2)+port(2)+target(hostname)
    encode_name(instance, &mut pkt);
    pkt.extend_from_slice(&TYPE_SRV.to_be_bytes());
    pkt.extend_from_slice(&(CLASS_IN | CACHE_FLUSH_BIT).to_be_bytes());
    pkt.extend_from_slice(&TTL_UNIQUE_S.to_be_bytes());
    let mut srv_rdata = Vec::new();
    srv_rdata.extend_from_slice(&0u16.to_be_bytes()); // priority
    srv_rdata.extend_from_slice(&0u16.to_be_bytes()); // weight
    srv_rdata.extend_from_slice(&ADMIN_PORT.to_be_bytes());
    encode_name(hostname, &mut srv_rdata);
    pkt.extend_from_slice(&(srv_rdata.len() as u16).to_be_bytes());
    pkt.extend_from_slice(&srv_rdata);

    // 3. TXT record — carries key=value pairs, at minimum node id and phi anchor.
    encode_name(instance, &mut pkt);
    pkt.extend_from_slice(&TYPE_TXT.to_be_bytes());
    pkt.extend_from_slice(&(CLASS_IN | CACHE_FLUSH_BIT).to_be_bytes());
    pkt.extend_from_slice(&TTL_UNIQUE_S.to_be_bytes());
    let mut txt_rdata = Vec::new();
    let node_pair = format!("node={node_id}");
    let phi_pair = "phi=3";
    let sim_pair = "sim=true";
    for pair in [node_pair.as_str(), phi_pair, sim_pair] {
        txt_rdata.push(pair.len() as u8);
        txt_rdata.extend_from_slice(pair.as_bytes());
    }
    pkt.extend_from_slice(&(txt_rdata.len() as u16).to_be_bytes());
    pkt.extend_from_slice(&txt_rdata);

    // 4. A record — hostname → admin_ip
    encode_name(hostname, &mut pkt);
    pkt.extend_from_slice(&TYPE_A.to_be_bytes());
    pkt.extend_from_slice(&(CLASS_IN | CACHE_FLUSH_BIT).to_be_bytes());
    pkt.extend_from_slice(&TTL_UNIQUE_S.to_be_bytes());
    pkt.extend_from_slice(&4u16.to_be_bytes());
    pkt.extend_from_slice(&admin_ip.octets());

    pkt
}

fn handle_query(
    pkt: &[u8],
    instance: &str,
    hostname: &str,
    admin_ip: Ipv4Addr,
    node_id: u16,
) -> Option<Vec<u8>> {
    let (txid, name, qtype) = parse_first_question(pkt)?;
    // Match against SERVICE (PTR discovery) or the instance name (SRV/TXT probe).
    let want_ptr = name.eq_ignore_ascii_case(SERVICE)
        && (qtype == mdns_wire::TYPE_PTR || qtype == 0xFF /* ANY */);
    let want_srv = name.eq_ignore_ascii_case(instance)
        && (qtype == mdns_wire::TYPE_SRV
            || qtype == mdns_wire::TYPE_TXT
            || qtype == 0xFF);
    let want_a =
        name.eq_ignore_ascii_case(hostname) && (qtype == mdns_wire::TYPE_A || qtype == 0xFF);
    if !(want_ptr || want_srv || want_a) {
        return None;
    }
    Some(build_reply(
        txid,
        instance,
        hostname,
        admin_ip,
        node_id,
        want_ptr,
    ))
}

// ─── silence unused warnings from binary layout ───────────────────────────
#[allow(dead_code)]
fn _keep(_a: SocketAddr, _b: SocketAddrV4) {}

// ─── tests ─────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // Craft a minimal mDNS query for _trinet-admin._tcp.local, qtype=PTR.
    fn craft_query(name: &str, qtype: u16) -> Vec<u8> {
        let mut pkt = Vec::new();
        // header: txid=0xBEEF, flags=0 (query), qd=1, an=0, ns=0, ar=0
        pkt.extend_from_slice(&0xBEEFu16.to_be_bytes());
        pkt.extend_from_slice(&0u16.to_be_bytes()); // flags
        pkt.extend_from_slice(&1u16.to_be_bytes()); // qd
        pkt.extend_from_slice(&0u16.to_be_bytes()); // an
        pkt.extend_from_slice(&0u16.to_be_bytes()); // ns
        pkt.extend_from_slice(&0u16.to_be_bytes()); // ar
        encode_name(name, &mut pkt);
        pkt.extend_from_slice(&qtype.to_be_bytes());
        pkt.extend_from_slice(&mdns_wire::CLASS_IN.to_be_bytes());
        pkt
    }

    #[test]
    fn parse_ptr_query_ok() {
        let pkt = craft_query(SERVICE, mdns_wire::TYPE_PTR);
        let (txid, name, qtype) = parse_first_question(&pkt).unwrap();
        assert_eq!(txid, 0xBEEF);
        assert_eq!(name, SERVICE);
        assert_eq!(qtype, mdns_wire::TYPE_PTR);
    }

    #[test]
    fn parse_rejects_answer_packet() {
        let mut pkt = craft_query(SERVICE, mdns_wire::TYPE_PTR);
        // flip QR bit
        pkt[2] = 0x80;
        assert!(parse_first_question(&pkt).is_none());
    }

    #[test]
    fn parse_rejects_short_packet() {
        assert!(parse_first_question(&[0u8; 5]).is_none());
    }

    #[test]
    fn build_reply_has_expected_answer_count() {
        let r = build_reply(
            0xBEEF,
            "trinet-admin-11._trinet-admin._tcp.local",
            "trinet-11.local",
            Ipv4Addr::new(10, 0, 0, 11),
            11,
            true,
        );
        // ancount at offset 6..8
        let an = u16::from_be_bytes([r[6], r[7]]);
        assert_eq!(an, 4);
        // txid preserved
        assert_eq!(u16::from_be_bytes([r[0], r[1]]), 0xBEEF);
        // flags = FLAGS_ANNOUNCE (0x8400)
        assert_eq!(
            u16::from_be_bytes([r[2], r[3]]),
            mdns_wire::FLAGS_ANNOUNCE
        );
    }

    #[test]
    fn handle_query_ignores_foreign_service() {
        let pkt = craft_query("_printer._tcp.local", mdns_wire::TYPE_PTR);
        let out = handle_query(
            &pkt,
            "trinet-admin-11._trinet-admin._tcp.local",
            "trinet-11.local",
            Ipv4Addr::new(10, 0, 0, 11),
            11,
        );
        assert!(out.is_none());
    }

    #[test]
    fn handle_query_answers_our_service() {
        let pkt = craft_query(SERVICE, mdns_wire::TYPE_PTR);
        let out = handle_query(
            &pkt,
            "trinet-admin-11._trinet-admin._tcp.local",
            "trinet-11.local",
            Ipv4Addr::new(10, 0, 0, 11),
            11,
        )
        .expect("must reply");
        // must contain the A-record IP octets
        let ip = Ipv4Addr::new(10, 0, 0, 11).octets();
        assert!(out.windows(4).any(|w| w == ip));
    }

    #[test]
    fn handle_query_reply_carries_admin_port() {
        let pkt = craft_query(SERVICE, mdns_wire::TYPE_PTR);
        let out = handle_query(
            &pkt,
            "trinet-admin-11._trinet-admin._tcp.local",
            "trinet-11.local",
            Ipv4Addr::new(10, 0, 0, 11),
            11,
        )
        .unwrap();
        let port_be = ADMIN_PORT.to_be_bytes();
        assert!(out.windows(2).any(|w| w == port_be));
    }
}
