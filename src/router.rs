//! M2 — IP-over-radio data plane (tri-net#11).
//!
//! A [`MeshRouter`] reads IP packets from the local TUN netdev, picks a next hop
//! toward the destination using the [`EtxTable`] metric, seals each packet
//! **hop-by-hop** (a separate ChaCha20-Poly1305 session per physical link), and
//! forwards through relays until it reaches the destination node, which hands
//! the payload back up to its TUN. This is what turns the M1 crypto core into a
//! routed mesh: encrypt/decrypt at every hop, ETX chooses the hop.
//!
//! Host-testable (`-sim`) over an in-process [`Transport`]; the real
//! `/dev/net/tun` binding + 5.8 GHz radio transport land on the Zynq-7020 Mini
//! ARM-Linux node. On the Mini the loop is:
//! `read tun -> node_of(dst_ip) -> send_ip(dst, pkt)`, and on `Delivery::Local`
//! write the payload back to the TUN device.

use crate::crypto::{MeshError, Session};
use crate::daemon::Transport;
use crate::routing::{EtxTable, NodeId};
use crate::wire::{FrameKind, Header};
use std::collections::HashMap;
use std::net::Ipv4Addr;

/// Default hop budget for a freshly originated packet.
pub const DEFAULT_TTL: u8 = 8;

/// Mesh subnet `10.42.0.0/24`: NodeId `n` (1..=254) ⇔ `10.42.0.n`.
pub fn mesh_ip(id: NodeId) -> Ipv4Addr {
    Ipv4Addr::new(10, 42, 0, (id & 0xff) as u8)
}

/// Recover the destination NodeId from a mesh IP, if it is in `10.42.0.0/24`.
pub fn node_of(ip: Ipv4Addr) -> Option<NodeId> {
    let o = ip.octets();
    if o[0] == 10 && o[1] == 42 && o[2] == 0 && (1..=254).contains(&o[3]) {
        Some(o[3] as NodeId)
    } else {
        None
    }
}

/// Why a packet was not delivered or forwarded.
#[derive(Debug, PartialEq, Eq)]
pub enum DropReason {
    /// No next hop toward the destination.
    NoRoute,
    /// Hop budget exhausted.
    TtlExpired,
    /// Frame from a node we have no session with, or it failed to open.
    Unopened(MeshError),
    /// Outbound seal failed (e.g. the per-key rekey hard cap was reached before
    /// a ratchet step) — the frame is dropped rather than risking nonce reuse.
    SealFailed(MeshError),
}

/// Outcome of handling one frame.
#[derive(Debug, PartialEq, Eq)]
pub enum Delivery {
    /// Packet was for this node — hand the payload up to the local TUN.
    Local(Vec<u8>),
    /// Packet was re-sealed and forwarded to `next_hop`.
    Forwarded(NodeId),
    /// Packet was dropped.
    Dropped(DropReason),
}

struct Link {
    session: Session,
    transport: Box<dyn Transport>,
}

/// A mesh node's routing/forwarding engine.
pub struct MeshRouter {
    id: NodeId,
    etx: EtxTable,
    /// One crypto session + transport per directly-linked neighbor.
    links: HashMap<NodeId, Link>,
    /// Learned overrides: destination → next-hop neighbor.
    routes: HashMap<NodeId, NodeId>,
}

impl MeshRouter {
    pub fn new(id: NodeId, etx_window: usize) -> Self {
        Self {
            id,
            etx: EtxTable::new(etx_window),
            links: HashMap::new(),
            routes: HashMap::new(),
        }
    }

    pub fn id(&self) -> NodeId {
        self.id
    }

    /// Register a directly-linked neighbor: its completed crypto session and the
    /// transport that reaches it.
    pub fn add_link(&mut self, peer: NodeId, session: Session, transport: Box<dyn Transport>) {
        self.links.insert(peer, Link { session, transport });
    }

    /// Feed a HELLO observation into the ETX metric (reverse = we heard them,
    /// forward = they reported hearing us).
    pub fn observe(&mut self, peer: NodeId, we_heard: bool, they_heard: bool) {
        self.etx.record(peer, we_heard, they_heard);
    }

    /// Neighbor ETX snapshot (id, etx), sorted by id — for status/printing.
    pub fn neighbors(&self) -> Vec<(NodeId, f32)> {
        self.etx.neighbors()
    }

    /// B03 fast-fail: declare a direct neighbor's link dead now, so `next_hop`
    /// reroutes immediately instead of waiting for the ETX estimate to decay.
    pub fn force_dead(&mut self, peer: NodeId) {
        self.etx.force_dead(peer);
    }

    /// Install an explicit route to a non-neighbor destination via `next_hop`.
    pub fn add_route(&mut self, dst: NodeId, next_hop: NodeId) {
        self.routes.insert(dst, next_hop);
    }

    /// Next hop toward `dst`: the destination itself if it is a direct neighbor,
    /// an installed route, else the best-ETX neighbor (relay).
    pub fn next_hop(&self, dst: NodeId) -> Option<NodeId> {
        if dst == self.id {
            return None;
        }
        // Use the direct link unless its ETX has gone infinite (dead) — that is
        // what lets traffic self-heal around a failed direct neighbor via a relay.
        let direct_dead = self.etx.etx(dst).is_some_and(|e| e.is_infinite());
        if self.links.contains_key(&dst) && !direct_dead {
            return Some(dst);
        }
        if let Some(&nh) = self.routes.get(&dst) {
            return Some(nh);
        }
        self.etx.best_next_hop().map(|(id, _)| id)
    }

    /// Originate an IP packet from the local TUN toward `dst`.
    pub fn send_ip(&mut self, dst: NodeId, payload: &[u8]) -> Delivery {
        let nh = match self.next_hop(dst) {
            Some(n) => n,
            None => return Delivery::Dropped(DropReason::NoRoute),
        };
        self.seal_to(
            nh,
            Header::new(FrameKind::Data, self.id, dst, DEFAULT_TTL),
            payload,
        )
    }

    /// Send `payload` straight to a directly-linked `peer`, bypassing routing.
    /// HELLO beacons use this: a node must beacon its direct links even when
    /// their ETX is infinite, so a recovered link can be re-detected.
    pub fn send_direct(&mut self, peer: NodeId, payload: &[u8]) -> Delivery {
        if !self.links.contains_key(&peer) {
            return Delivery::Dropped(DropReason::NoRoute);
        }
        self.seal_to(
            peer,
            Header::new(FrameKind::Data, self.id, peer, DEFAULT_TTL),
            payload,
        )
    }

    /// Handle a frame received from directly-linked neighbor `from`.
    pub fn handle_frame(&mut self, from: NodeId, raw: &[u8]) -> Delivery {
        if raw.len() < Header::LEN {
            return Delivery::Dropped(DropReason::Unopened(MeshError::ShortFrame));
        }
        let (hdr_bytes, body) = raw.split_at(Header::LEN);

        // Open under the *receiving link's* session (hop-by-hop crypto). The
        // authenticated header carries the end-to-end src/dst.
        let payload = match self.links.get_mut(&from) {
            Some(link) => match link.session.open(hdr_bytes, body) {
                Ok(p) => p,
                Err(e) => return Delivery::Dropped(DropReason::Unopened(e)),
            },
            None => return Delivery::Dropped(DropReason::Unopened(MeshError::Auth)),
        };
        let hdr = match Header::parse(hdr_bytes) {
            Some(h) => h,
            None => return Delivery::Dropped(DropReason::Unopened(MeshError::Auth)),
        };

        if hdr.dst == self.id {
            return Delivery::Local(payload);
        }
        if hdr.ttl == 0 {
            return Delivery::Dropped(DropReason::TtlExpired);
        }
        let nh = match self.next_hop(hdr.dst) {
            Some(n) => n,
            None => return Delivery::Dropped(DropReason::NoRoute),
        };
        // Re-seal end-to-end payload under the outgoing link, TTL-1.
        self.seal_to(
            nh,
            Header::new(FrameKind::Data, hdr.src, hdr.dst, hdr.ttl - 1),
            &payload,
        )
    }

    /// Seal `payload` under the session for `nh`, prepend the authenticated
    /// header, and push it onto that link's transport.
    fn seal_to(&mut self, nh: NodeId, header: Header, payload: &[u8]) -> Delivery {
        let hdr = header.to_bytes();
        match self.links.get_mut(&nh) {
            Some(link) => match link.session.seal(&hdr, payload) {
                Ok(sealed) => {
                    let mut frame = hdr.to_vec();
                    frame.extend_from_slice(&sealed);
                    let _ = link.transport.send(&frame);
                    Delivery::Forwarded(nh)
                }
                Err(e) => Delivery::Dropped(DropReason::SealFailed(e)),
            },
            None => Delivery::Dropped(DropReason::NoRoute),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::Handshake;
    use std::collections::VecDeque;
    use std::io;
    use std::sync::{Arc, Mutex};

    /// In-process transport: `send` appends to a shared queue the test reads.
    #[derive(Clone, Default)]
    struct VecTransport {
        q: Arc<Mutex<VecDeque<Vec<u8>>>>,
    }
    impl Transport for VecTransport {
        fn send(&mut self, frame: &[u8]) -> io::Result<()> {
            self.q.lock().unwrap().push_back(frame.to_vec());
            Ok(())
        }
        fn recv(&mut self) -> io::Result<Vec<u8>> {
            self.q
                .lock()
                .unwrap()
                .pop_front()
                .ok_or_else(|| io::Error::new(io::ErrorKind::WouldBlock, "empty"))
        }
    }
    impl VecTransport {
        fn take(&self) -> Vec<u8> {
            self.q
                .lock()
                .unwrap()
                .pop_front()
                .expect("a frame was sent")
        }
    }

    /// A pair of matched sessions (initiator, responder) from one X25519 DH.
    fn sessions() -> (Session, Session) {
        let a = Handshake::new();
        let b = Handshake::new();
        let (ap, bp) = (a.public, b.public);
        (a.complete(&bp, true), b.complete(&ap, false))
    }

    #[test]
    fn addr_roundtrips_in_subnet() {
        assert_eq!(mesh_ip(5), Ipv4Addr::new(10, 42, 0, 5));
        assert_eq!(node_of(Ipv4Addr::new(10, 42, 0, 5)), Some(5));
        assert_eq!(node_of(Ipv4Addr::new(192, 168, 0, 5)), None);
        assert_eq!(node_of(Ipv4Addr::new(10, 42, 0, 0)), None); // .0 not a host
    }

    #[test]
    fn direct_delivery() {
        let (sa, sb) = sessions();
        let t = VecTransport::default();
        let mut a = MeshRouter::new(1, 16);
        let mut b = MeshRouter::new(2, 16);
        a.add_link(2, sa, Box::new(t.clone()));
        b.add_link(1, sb, Box::new(VecTransport::default()));

        assert_eq!(a.send_ip(2, b"ip-packet"), Delivery::Forwarded(2));
        let frame = t.take();
        assert_eq!(
            b.handle_frame(1, &frame),
            Delivery::Local(b"ip-packet".to_vec())
        );
    }

    #[test]
    fn two_hop_relay_with_hop_by_hop_crypto() {
        // A(1) — C(3) — B(2). A has no direct link to B; it must relay via C.
        let (a_c, c_a) = sessions(); // A<->C
        let (c_b, b_c) = sessions(); // C<->B
        let ac = VecTransport::default(); // A -> C
        let cb = VecTransport::default(); // C -> B

        let mut a = MeshRouter::new(1, 16);
        let mut c = MeshRouter::new(3, 16);
        let mut b = MeshRouter::new(2, 16);

        a.add_link(3, a_c, Box::new(ac.clone()));
        c.add_link(1, c_a, Box::new(VecTransport::default()));
        c.add_link(2, c_b, Box::new(cb.clone()));
        b.add_link(3, b_c, Box::new(VecTransport::default()));

        // A learns C is a good neighbor so best_next_hop(→ relay) resolves to C.
        for _ in 0..4 {
            a.observe(3, true, true);
        }
        assert_eq!(a.next_hop(2), Some(3), "A relays toward B via C");

        // A originates to B → goes to C.
        assert_eq!(a.send_ip(2, b"hello over 2 hops"), Delivery::Forwarded(3));
        let f1 = ac.take();

        // C receives from A, sees dst=B, re-seals under the C<->B session → B.
        assert_eq!(c.handle_frame(1, &f1), Delivery::Forwarded(2));
        let f2 = cb.take();
        assert_ne!(
            f1, f2,
            "each hop is independently encrypted (different ciphertext)"
        );

        // B receives the relayed frame from C and delivers locally.
        assert_eq!(
            b.handle_frame(3, &f2),
            Delivery::Local(b"hello over 2 hops".to_vec())
        );
    }

    #[test]
    fn ttl_expiry_is_dropped() {
        let (sa, sb) = sessions(); // A(1) <-> C(3)
        let mut a = MeshRouter::new(1, 16);
        let mut c = MeshRouter::new(3, 16);
        a.add_link(3, sa, Box::new(VecTransport::default()));
        c.add_link(1, sb, Box::new(VecTransport::default()));

        // Craft a frame addressed to B(2) with ttl already 0, sealed under the
        // A/C link; C must refuse to forward it.
        let hdr = Header::new(FrameKind::Data, 1, 2, 0).to_bytes();
        let body = {
            let link = a.links.get_mut(&3).unwrap();
            link.session.seal(&hdr, b"x").unwrap()
        };
        let mut frame = hdr.to_vec();
        frame.extend_from_slice(&body);
        assert_eq!(
            c.handle_frame(1, &frame),
            Delivery::Dropped(DropReason::TtlExpired)
        );
    }

    #[test]
    fn no_route_is_dropped() {
        let mut a = MeshRouter::new(1, 16);
        assert_eq!(a.send_ip(2, b"x"), Delivery::Dropped(DropReason::NoRoute));
    }

    #[test]
    fn frame_from_unknown_link_is_dropped() {
        let (sa, _sb) = sessions();
        let mut a = MeshRouter::new(1, 16);
        a.add_link(2, sa, Box::new(VecTransport::default()));
        // A never linked node 9 → cannot open its frame.
        let junk = vec![0u8; Header::LEN + 32];
        assert_eq!(
            a.handle_frame(9, &junk),
            Delivery::Dropped(DropReason::Unopened(MeshError::Auth))
        );
    }

    #[test]
    fn dead_direct_link_reroutes_via_relay() {
        // Node 1 links directly to relay 2 and destination 3 (small ETX window).
        let (s2, _) = sessions();
        let (s3, _) = sessions();
        let mut a = MeshRouter::new(1, 4);
        a.add_link(2, s2, Box::new(VecTransport::default()));
        a.add_link(3, s3, Box::new(VecTransport::default()));
        // Both links healthy → route to 3 is direct.
        for _ in 0..4 {
            a.observe(2, true, true);
            a.observe(3, true, true);
        }
        assert_eq!(a.next_hop(3), Some(3));
        // The direct 1<->3 link dies (sustained loss); 1<->2 stays healthy.
        for _ in 0..5 {
            a.observe(2, true, true);
            a.observe(3, false, false);
        }
        assert_eq!(
            a.next_hop(3),
            Some(2),
            "route to 3 must self-heal via relay 2"
        );
    }
}
