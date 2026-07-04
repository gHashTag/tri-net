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
use std::time::Instant;

/// A byte-pipe to one neighbor. Real impls: a UDP socket (bench, over
/// attenuators), a TUN-backed radio netdev (M2), or an in-process pipe (tests).
pub trait Transport: Send {
    fn send(&mut self, frame: &[u8]) -> std::io::Result<()>;
    fn recv(&mut self) -> std::io::Result<Vec<u8>>;
}

/// E6: Convergence metrics tracking self-heal performance.
#[derive(Debug, Clone)]
pub struct ConvergenceMetrics {
    /// Time from link loss detection to reroute completion (milliseconds).
    pub link_loss_to_reroute_ms: Option<f32>,
    /// Time from node failure detection to reroute completion (milliseconds).
    pub node_off_to_reroute_ms: Option<f32>,
}

impl ConvergenceMetrics {
    pub fn new() -> Self {
        Self {
            link_loss_to_reroute_ms: None,
            node_off_to_reroute_ms: None,
        }
    }

    /// Record link loss reroute time.
    pub fn record_link_loss(&mut self, duration_ms: f32) {
        self.link_loss_to_reroute_ms = Some(duration_ms);
    }

    /// Record node failure reroute time.
    pub fn record_node_off(&mut self, duration_ms: f32) {
        self.node_off_to_reroute_ms = Some(duration_ms);
    }

    /// Check CI gates: <5s for link, <10s for node.
    pub fn check_ci_gates(&self) -> Result<(), String> {
        if let Some(link_ms) = self.link_loss_to_reroute_ms {
            if link_ms >= 5000.0 {
                return Err(format!(
                    "Link convergence too slow: {}ms (CI gate: <5000ms)",
                    link_ms
                ));
            }
        }

        if let Some(node_ms) = self.node_off_to_reroute_ms {
            if node_ms >= 10000.0 {
                return Err(format!(
                    "Node convergence too slow: {}ms (CI gate: <10000ms)",
                    node_ms
                ));
            }
        }

        Ok(())
    }

    /// Emit metrics as JSON to stdout.
    pub fn emit_json(&self) {
        let json = serde_json::json!({
            "link_loss_to_reroute_ms": self.link_loss_to_reroute_ms,
            "node_off_to_reroute_ms": self.node_off_to_reroute_ms,
        });
        println!("{}", json);
    }
}

impl Default for ConvergenceMetrics {
    fn default() -> Self {
        Self::new()
    }
}

/// A mesh node: its id, the ETX neighbor table, and one crypto session per peer.
pub struct Node {
    pub id: NodeId,
    pub etx: EtxTable,
    sessions: HashMap<NodeId, Session>,
    /// E6: Convergence metrics for self-heal performance.
    pub metrics: ConvergenceMetrics,
    /// E6: Timestamp tracking for convergence measurements.
    link_loss_detected: Option<Instant>,
    node_off_detected: Option<Instant>,
}

impl Node {
    pub fn new(id: NodeId, etx_window: usize) -> Self {
        Self {
            id,
            etx: EtxTable::new(etx_window),
            sessions: HashMap::new(),
            metrics: ConvergenceMetrics::new(),
            link_loss_detected: None,
            node_off_detected: None,
        }
    }

    /// Install the completed crypto session for `peer` (after the X25519 handshake).
    pub fn add_session(&mut self, peer: NodeId, session: Session) {
        self.sessions.insert(peer, session);
    }

    pub fn has_session(&self, peer: NodeId) -> bool {
        self.sessions.contains_key(&peer)
    }

    /// E6: Mark link loss detected (start convergence timer).
    pub fn on_link_loss_detected(&mut self) {
        self.link_loss_detected = Some(Instant::now());
    }

    /// E6: Mark node failure detected (start convergence timer).
    pub fn on_node_off_detected(&mut self) {
        self.node_off_detected = Some(Instant::now());
    }

    /// E6: Mark reroute completed (stop timers and record metrics).
    pub fn on_reroute_completed(&mut self) {
        // Record link loss convergence
        if let Some(detected) = self.link_loss_detected {
            let elapsed = detected.elapsed();
            self.metrics
                .record_link_loss(elapsed.as_secs_f32() * 1000.0);
            self.link_loss_detected = None;
        }

        // Record node failure convergence
        if let Some(detected) = self.node_off_detected {
            let elapsed = detected.elapsed();
            self.metrics.record_node_off(elapsed.as_secs_f32() * 1000.0);
            self.node_off_detected = None;
        }

        // Emit JSON metrics
        self.metrics.emit_json();
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

    // E6: Convergence metrics tests

    #[test]
    fn convergence_metrics_initial_empty() {
        let metrics = ConvergenceMetrics::new();
        assert!(metrics.link_loss_to_reroute_ms.is_none());
        assert!(metrics.node_off_to_reroute_ms.is_none());
    }

    #[test]
    fn convergence_metrics_records_link_loss() {
        let mut metrics = ConvergenceMetrics::new();
        metrics.record_link_loss(1234.5);
        assert_eq!(metrics.link_loss_to_reroute_ms, Some(1234.5));
    }

    #[test]
    fn convergence_metrics_records_node_off() {
        let mut metrics = ConvergenceMetrics::new();
        metrics.record_node_off(5678.9);
        assert_eq!(metrics.node_off_to_reroute_ms, Some(5678.9));
    }

    #[test]
    fn convergence_ci_gate_pass_fast_link() {
        let mut metrics = ConvergenceMetrics::new();
        metrics.record_link_loss(1000.0); // <5000ms, should pass
        assert!(metrics.check_ci_gates().is_ok());
    }

    #[test]
    fn convergence_ci_gate_pass_fast_node() {
        let mut metrics = ConvergenceMetrics::new();
        metrics.record_node_off(5000.0); // <10000ms, should pass
        assert!(metrics.check_ci_gates().is_ok());
    }

    #[test]
    fn convergence_ci_gate_fail_slow_link() {
        let mut metrics = ConvergenceMetrics::new();
        metrics.record_link_loss(6000.0); // >=5000ms, should fail
        assert!(metrics.check_ci_gates().is_err());
    }

    #[test]
    fn convergence_ci_gate_fail_slow_node() {
        let mut metrics = ConvergenceMetrics::new();
        metrics.record_node_off(11000.0); // >=10000ms, should fail
        assert!(metrics.check_ci_gates().is_err());
    }

    #[test]
    fn convergence_emit_json_valid() {
        let mut metrics = ConvergenceMetrics::new();
        metrics.record_link_loss(1234.5);
        metrics.record_node_off(5678.9);

        // This would emit JSON in real usage
        // For testing, just verify it doesn't panic
        metrics.emit_json();
    }

    #[test]
    fn node_tracks_link_loss_detection() {
        let mut node = Node::new(1, 16);
        assert!(node.link_loss_detected.is_none());

        node.on_link_loss_detected();
        assert!(node.link_loss_detected.is_some());
    }

    #[test]
    fn node_tracks_node_off_detection() {
        let mut node = Node::new(1, 16);
        assert!(node.node_off_detected.is_none());

        node.on_node_off_detected();
        assert!(node.node_off_detected.is_some());
    }

    #[test]
    fn node_completes_reroute_records_metrics() {
        let mut node = Node::new(1, 16);

        // Simulate link loss
        node.on_link_loss_detected();
        std::thread::sleep(std::time::Duration::from_millis(10));
        node.on_reroute_completed();

        // Metrics should be recorded
        assert!(node.metrics.link_loss_to_reroute_ms.is_some());
        assert!(node.metrics.link_loss_to_reroute_ms.unwrap() >= 10.0);

        // Timer should be cleared
        assert!(node.link_loss_detected.is_none());
    }

    #[test]
    fn node_ci_gate_enforced() {
        let mut node = Node::new(1, 16);

        // Fast convergence (should pass)
        node.metrics.record_link_loss(1000.0);
        node.metrics.record_node_off(5000.0);
        assert!(node.metrics.check_ci_gates().is_ok());

        // Slow convergence (should fail)
        node.metrics.record_link_loss(6000.0);
        assert!(node.metrics.check_ci_gates().is_err());
    }

    #[test]
    fn unknown_peer_has_no_session() {
        let (mut a, _b) = linked(1, 2);
        assert!(a.seal_data(99, 8, b"x").is_none());
    }
}
