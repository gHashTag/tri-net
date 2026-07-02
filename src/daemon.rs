//! Node skeleton wiring crypto + routing + wire framing together.
//!
//! The production node reads IP packets from a Linux **TUN** device, seals each
//! one to the best next hop, and writes it to the 5.8 GHz radio transport; the
//! reverse path opens frames and injects them back into TUN. That TUN + radio
//! I/O is milestone **M2** (tri-net#11) and is intentionally abstracted behind
//! the [`Transport`] trait so M1 can be exercised host-side without hardware.

use crate::crypto::{MeshError, Session};
use crate::routing::{EtxTable, NodeId};
use crate::wire::{FrameKind, Header};
use std::collections::HashMap;

/// A byte-pipe to one neighbor. Real impls: a UDP socket (bench, over
/// attenuators), a TUN-backed radio netdev (M2), or an in-process pipe (tests).
pub trait Transport: Send {
    fn send(&mut self, frame: &[u8]) -> std::io::Result<()>;
    fn recv(&mut self) -> std::io::Result<Vec<u8>>;
}

/// A mesh node: its id, the ETX neighbor table, and one crypto session per peer.
pub struct Node {
    pub id: NodeId,
    pub etx: EtxTable,
    sessions: HashMap<NodeId, Session>,
}

impl Node {
    pub fn new(id: NodeId, etx_window: usize) -> Self {
        Self {
            id,
            etx: EtxTable::new(etx_window),
            sessions: HashMap::new(),
        }
    }

    /// Install the completed crypto session for `peer` (after the X25519 handshake).
    pub fn add_session(&mut self, peer: NodeId, session: Session) {
        self.sessions.insert(peer, session);
    }

    pub fn has_session(&self, peer: NodeId) -> bool {
        self.sessions.contains_key(&peer)
    }

    /// Seal an IP payload to `dst`. The wire header authenticates as AAD, so a
    /// flipped src/dst/ttl byte makes the peer's `open` fail.
    ///
    /// Returns `None` if there is no session for `dst`, or if the session hit its
    /// per-key hard cap ([`crate::crypto::MeshError::RekeyRequired`]) and must be
    /// ratcheted before sealing again. Driving that ratchet on a timer belongs to
    /// the M2 run loop (tri-net#11); the M1 skeleton simply declines to seal
    /// rather than risk a nonce reuse. The frame-count auto-ratchet inside `seal`
    /// keeps this path from being hit under normal traffic.
    pub fn seal_data(&mut self, dst: NodeId, ttl: u8, payload: &[u8]) -> Option<Vec<u8>> {
        let header = Header::new(FrameKind::Data, self.id, dst, ttl).to_bytes();
        let session = self.sessions.get_mut(&dst)?;
        let sealed = session.seal(&header, payload).ok()?;
        let mut frame = header.to_vec();
        frame.extend_from_slice(&sealed);
        Some(frame)
    }

    /// Open a frame from `src`. Returns the plaintext IP payload.
    pub fn open_data(&mut self, src: NodeId, frame: &[u8]) -> Result<Vec<u8>, MeshError> {
        if frame.len() < Header::LEN {
            return Err(MeshError::ShortFrame);
        }
        let (header, body) = frame.split_at(Header::LEN);
        let session = self.sessions.get_mut(&src).ok_or(MeshError::Auth)?;
        session.open(header, body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::Handshake;

    fn linked(a_id: NodeId, b_id: NodeId) -> (Node, Node) {
        let a = Handshake::new();
        let b = Handshake::new();
        let (a_pub, b_pub) = (a.public, b.public);
        let mut na = Node::new(a_id, 16);
        let mut nb = Node::new(b_id, 16);
        na.add_session(b_id, a.complete(&b_pub, true));
        nb.add_session(a_id, b.complete(&a_pub, false));
        (na, nb)
    }

    #[test]
    fn data_frame_seals_and_opens() {
        let (mut a, mut b) = linked(1, 2);
        let frame = a.seal_data(2, 8, b"ip-packet").unwrap();
        assert_eq!(b.open_data(1, &frame).unwrap(), b"ip-packet");
    }

    #[test]
    fn tampered_header_fails_auth() {
        let (mut a, mut b) = linked(1, 2);
        let mut frame = a.seal_data(2, 8, b"ip-packet").unwrap();
        frame[10] ^= 0xff; // corrupt the ttl byte (part of the AAD header)
        assert_eq!(b.open_data(1, &frame), Err(MeshError::Auth));
    }

    #[test]
    fn unknown_peer_has_no_session() {
        let (mut a, _b) = linked(1, 2);
        assert!(a.seal_data(99, 8, b"x").is_none());
    }
}
