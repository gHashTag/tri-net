//! trios-mesh library - encrypted, self-routing IP-over-radio mesh primitives.
//!
//! The hand-written modules below are the current runtime surface. The
//! generated `gen/rust/` stubs are excluded from compilation until `t27c` is
//! available to produce valid Rust from `specs/*.t27`.
//!
//! phi^2 + phi^-2 = 3

// Tests assert on infallible test-only roundtrips; unwrap_used is allowed in
// test code while production code remains covered by the workspace deny lint.
#![cfg_attr(test, allow(clippy::unwrap_used))]

pub mod crypto;
pub mod daemon;
pub mod discovery;
pub mod gf16;
pub mod modem;
pub mod router;
pub mod routing;
pub mod wire;

// Types used across the crate
pub type NodeId = u32;

/// Delivery confirmation for mesh forwarding.
#[derive(Debug, Clone)]
pub struct Delivery {
    pub src: NodeId,
    pub dst: NodeId,
    pub hops: u8,
}

/// Hello beacon payload.
#[derive(Debug, Clone)]
pub struct Hello {
    pub src: NodeId,
    pub seq: u32,
    pub neighbors: Vec<(NodeId, u8)>,
}

/// Static key type for pre-shared-key mesh.
pub struct StaticKey {
    pub secret: [u8; 32],
}

/// Transport abstraction (UDP now, radio later).
pub trait Transport: Send {
    fn send_to(&self, data: &[u8], dst: std::net::SocketAddr) -> std::io::Result<()>;
    fn recv_from(&self, buf: &mut [u8]) -> std::io::Result<(usize, std::net::SocketAddr)>;
}

/// Mesh router trait.
pub trait MeshRouter: Send {
    fn add_neighbor(&mut self, id: NodeId, addr: std::net::SocketAddr, etx: u8);
    fn remove_neighbor(&mut self, id: NodeId);
    fn next_hop(&self, dst: NodeId) -> Option<(NodeId, std::net::SocketAddr)>;
    fn neighbors(&self) -> Vec<(NodeId, std::net::SocketAddr)>;
}
