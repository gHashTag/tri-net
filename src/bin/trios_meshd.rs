//! trios-meshd — minimal TRI-NET mesh daemon over a UDP transport.
//!
//! Runs on each node. Uses UDP-over-Ethernet as the link transport (stand-in
//! for the 5.8 GHz radio, which swaps in later as a different `Transport`), so
//! the full mesh stack — per-hop ChaCha20-Poly1305 crypto, ETX routing from
//! HELLO beacons, and multi-hop forwarding — can be validated on real hardware
//! WITHOUT radiating anything (legally clean for development).
//!
//! Demo keys are derived deterministically from node id (a pre-shared-key mesh,
//! an allow-list); real ephemeral auth is the Noise-XX path (tri-net#… / B01).
//!
//! Config file (one directive per line):
//!   id 11
//!   listen 0.0.0.0:5000
//!   peer 12 192.168.1.12:5000
//! Run: `trios-meshd <config>`   optional: `TRIOS_SEND=13:hello` sends one test packet.

use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::io;
use std::net::{SocketAddr, UdpSocket};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use trios_mesh::{Delivery, Hello, MeshRouter, NodeId, StaticKey, Transport};

const HELLO_MS: u64 = 300;
const ETX_WINDOW: usize = 3;
/// B03: consecutive missed HELLOs before a link is declared dead (fast-fail).
const FAST_FAIL_MISSES: u32 = 2;
const HELLO_TYPE: u8 = 0;
const DATA_TYPE: u8 = 1;
const FETCH_REQ: u8 = 2; // "fetch the internet for me" (M4 shared uplink)
const FETCH_RESP: u8 = 3; // gateway's reply carrying the fetched bytes

/// Deterministic demo static key from a node id.
fn seed_for(id: NodeId) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(b"trios-mesh/demo/v1/node/");
    h.update(id.to_le_bytes());
    h.finalize().into()
}

/// Gateway-side internet fetch (M4): GET the caller's public IP. Runs only on
/// the node that actually has an uplink; the result travels back over the mesh.
fn fetch_public_ip() -> String {
    use std::io::{Read, Write};
    match std::net::TcpStream::connect("api.ipify.org:80") {
        Ok(mut s) => {
            let _ = s.set_read_timeout(Some(Duration::from_secs(6)));
            let _ =
                s.write_all(b"GET / HTTP/1.0\r\nHost: api.ipify.org\r\nConnection: close\r\n\r\n");
            let mut buf = String::new();
            let _ = s.read_to_string(&mut buf);
            buf.rsplit("\r\n\r\n")
                .next()
                .unwrap_or("")
                .trim()
                .to_string()
        }
        Err(e) => format!("ERR: {e}"),
    }
}

/// A link transport that sends datagrams to one peer over a shared UDP socket.
/// (RX is handled centrally by the daemon, so `recv` is unused.)
struct UdpLink {
    sock: Arc<UdpSocket>,
    peer: SocketAddr,
}
impl Transport for UdpLink {
    fn send(&mut self, frame: &[u8]) -> io::Result<()> {
        self.sock.send_to(frame, self.peer).map(|_| ())
    }
    fn recv(&mut self) -> io::Result<Vec<u8>> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "central rx"))
    }
}

struct Cfg {
    id: NodeId,
    listen: SocketAddr,
    peers: Vec<(NodeId, SocketAddr)>,
}

fn parse_cfg(text: &str) -> Cfg {
    let mut id = 0u32;
    let mut listen = None;
    let mut peers = Vec::new();
    for line in text.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        match f.as_slice() {
            ["id", v] => id = v.parse().expect("id"),
            ["listen", a] => listen = Some(a.parse().expect("listen addr")),
            ["peer", pid, a] => {
                peers.push((pid.parse().expect("peer id"), a.parse().expect("peer addr")))
            }
            _ => {}
        }
    }
    Cfg {
        id,
        listen: listen.unwrap_or_else(|| SocketAddr::from(([0, 0, 0, 0], 5000))),
        peers,
    }
}

#[derive(Default)]
struct RxShared {
    seen: HashSet<NodeId>,
    they_heard: HashMap<NodeId, bool>,
}

fn main() {
    let path = std::env::args()
        .nth(1)
        .expect("usage: trios-meshd <config>");
    let cfg = parse_cfg(&std::fs::read_to_string(&path).expect("read config"));
    let me = cfg.id;
    let my_key = StaticKey::from_seed(seed_for(me));

    let sock = Arc::new(UdpSocket::bind(cfg.listen).expect("bind"));
    let mut router = MeshRouter::new(me, ETX_WINDOW);
    let mut peer_ids: Vec<NodeId> = Vec::new();
    // Key by full SocketAddr (IP + port) so that loopback smokes with
    // three nodes on 127.0.0.1:5011/5012/5013 don't collide on a shared IP.
    // On real hardware every board has a unique IP, so this is a strict
    // superset of the previous behaviour and never wrong.
    // phi^2 + phi^-2 = 3
    let mut addr_to_id: HashMap<SocketAddr, NodeId> = HashMap::new();
    for (pid, addr) in &cfg.peers {
        let peer_pub = StaticKey::from_seed(seed_for(*pid)).public();
        let session = my_key.session_with(&peer_pub, me < *pid);
        router.add_link(
            *pid,
            session,
            Box::new(UdpLink {
                sock: sock.clone(),
                peer: *addr,
            }),
        );
        peer_ids.push(*pid);
        addr_to_id.insert(*addr, *pid);
    }
    let router = Arc::new(Mutex::new(router));
    let rx = Arc::new(Mutex::new(RxShared::default()));
    // Peers whose link is simulated-failed (ids in /tmp/mesh.drop) — for M5 demo.
    let dropped: Arc<Mutex<HashSet<NodeId>>> = Arc::new(Mutex::new(HashSet::new()));
    let watch: Option<NodeId> = std::env::var("TRIOS_WATCH")
        .ok()
        .and_then(|s| s.parse().ok());
    // M4: this node has a real internet uplink and serves FETCH requests.
    let gateway = std::env::var("TRIOS_GATEWAY").is_ok();
    let started = Instant::now();
    println!("[meshd] node {me} on {} — peers {peer_ids:?}", cfg.listen);

    // Central RX: dispatch every datagram through the router.
    {
        let (sock, router, rx, addr_to_id, dropped) = (
            sock.clone(),
            router.clone(),
            rx.clone(),
            addr_to_id.clone(),
            dropped.clone(),
        );
        thread::spawn(move || {
            let mut buf = [0u8; 2048];
            loop {
                let (n, src) = match sock.recv_from(&mut buf) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                let from = match addr_to_id.get(&src) {
                    Some(f) => *f,
                    None => continue,
                };
                if dropped.lock().unwrap().contains(&from) {
                    continue; // simulated link failure: ignore this neighbor
                }
                let deliv = router.lock().unwrap().handle_frame(from, &buf[..n]);
                match deliv {
                    Delivery::Local(p) if p.first() == Some(&HELLO_TYPE) => {
                        if let Some(h) = Hello::parse(&p[1..]) {
                            let mut r = rx.lock().unwrap();
                            r.seen.insert(from);
                            r.they_heard.insert(from, h.reports_hearing(me));
                        }
                    }
                    Delivery::Local(p) if p.first() == Some(&DATA_TYPE) => {
                        println!(
                            "[meshd] DELIVERED (last hop {from}): {}",
                            String::from_utf8_lossy(&p[1..])
                        );
                    }
                    // M4: a node asked us (the gateway) to reach the internet.
                    Delivery::Local(p)
                        if p.first() == Some(&FETCH_REQ) && gateway && p.len() >= 5 =>
                    {
                        let origin = u32::from_le_bytes([p[1], p[2], p[3], p[4]]);
                        let router = router.clone();
                        thread::spawn(move || {
                            let ip = fetch_public_ip();
                            let mut resp = vec![FETCH_RESP];
                            resp.extend_from_slice(ip.as_bytes());
                            let d = router.lock().unwrap().send_ip(origin, &resp);
                            println!(
                                "[meshd] gateway fetched \"{ip}\" -> reply to {origin}: {d:?}"
                            );
                        });
                    }
                    // M4: the gateway's reply — internet reached us over the mesh.
                    Delivery::Local(p) if p.first() == Some(&FETCH_RESP) => {
                        println!(
                            "[meshd] INTERNET-VIA-MESH: {}",
                            String::from_utf8_lossy(&p[1..])
                        );
                    }
                    Delivery::Forwarded(nh) => println!("[meshd] relayed -> {nh}"),
                    _ => {}
                }
            }
        });
    }

    // Optional one-shot test packet: TRIOS_SEND="dst:message".
    if let Ok(spec) = std::env::var("TRIOS_SEND") {
        if let Some((d, m)) = spec.split_once(':') {
            let dst: NodeId = d.parse().expect("send dst");
            let msg = m.as_bytes().to_vec();
            let router = router.clone();
            thread::spawn(move || {
                thread::sleep(Duration::from_secs(4));
                let mut payload = vec![DATA_TYPE];
                payload.extend_from_slice(&msg);
                let d = router.lock().unwrap().send_ip(dst, &payload);
                println!("[meshd] TX test -> {dst}: {d:?}");
            });
        }
    }

    // M4 requester: ask the gateway (id = TRIOS_FETCH) to reach the internet on
    // our behalf, routed over the mesh (we have no direct uplink).
    if let Ok(gwid) = std::env::var("TRIOS_FETCH") {
        if let Ok(gw) = gwid.parse::<NodeId>() {
            let router = router.clone();
            thread::spawn(move || {
                thread::sleep(Duration::from_secs(5));
                let mut req = vec![FETCH_REQ];
                req.extend_from_slice(&me.to_le_bytes());
                let d = router.lock().unwrap().send_ip(gw, &req);
                println!("[meshd] FETCH internet via mesh -> gateway {gw}: {d:?}");
            });
        }
    }

    // Ticker: measure ETX for the interval, beacon HELLO, print status.
    let mut seq = 0u32;
    let mut tick = 0u64;
    let mut misses: HashMap<NodeId, u32> = HashMap::new();
    loop {
        thread::sleep(Duration::from_millis(HELLO_MS));
        seq += 1;
        tick += 1;
        let (seen, they) = {
            let mut r = rx.lock().unwrap();
            (std::mem::take(&mut r.seen), r.they_heard.clone())
        };
        let heard: Vec<NodeId> = {
            let mut v: Vec<NodeId> = seen.iter().copied().collect();
            v.sort();
            v
        };
        // Refresh the simulated link-failure set from /tmp/mesh.drop (M5 control).
        let dset: HashSet<NodeId> = std::fs::read_to_string("/tmp/mesh.drop")
            .ok()
            .map(|s| {
                s.split_whitespace()
                    .filter_map(|x| x.parse().ok())
                    .collect()
            })
            .unwrap_or_default();
        *dropped.lock().unwrap() = dset.clone();

        let mut rt = router.lock().unwrap();
        for pid in &peer_ids {
            let alive = !dset.contains(pid);
            let heard = seen.contains(pid) && alive;
            rt.observe(*pid, heard, *they.get(pid).unwrap_or(&false) && alive);
            if heard {
                misses.insert(*pid, 0);
            } else {
                let m = misses.entry(*pid).or_insert(0);
                *m += 1;
                if *m >= FAST_FAIL_MISSES {
                    rt.force_dead(*pid); // B03: reroute now, don't wait for decay
                }
            }
        }
        // E2.2 — Use authenticated HELLO with MAC
        // TODO: derive mac_key from session keys (E2.2 complete implementation)
        let mac_key = None; // Will be derived from per-peer session keys
        let hello = Hello::authenticated(me, seq, heard, &mac_key);
        let mut pay = vec![HELLO_TYPE];
        pay.extend_from_slice(&hello.to_bytes());
        for pid in &peer_ids {
            if dset.contains(pid) {
                continue; // don't beacon over a failed link
            }
            let _ = rt.send_direct(*pid, &pay); // beacons bypass routing
        }
        if let Some(w) = watch {
            println!(
                "[meshd] t={:.1}s node {me} route->{w} via {:?}",
                started.elapsed().as_secs_f32(),
                rt.next_hop(w)
            );
        }
        if tick.is_multiple_of(3) {
            let s: Vec<String> = rt
                .neighbors()
                .iter()
                .map(|(id, e)| {
                    let v = if e.is_finite() {
                        format!("{e:.2}")
                    } else {
                        "inf".into()
                    };
                    format!("{id}={v}")
                })
                .collect();
            println!("[meshd] node {me} neighbors {{ {} }}", s.join(", "));
        }
    }
}
