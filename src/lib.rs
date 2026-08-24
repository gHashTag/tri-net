//! trios-mesh library — re-export hub for generated code.
//!
//! All business logic lives in gen/rust/ (generated from specs/*.t27).
//! This file ONLY re-exports. No hand-written logic.
//!
//! Pipeline: specs/*.t27 -> t27c gen-rust -> gen/rust/ -> src/
//!
//! phi^2 + phi^-2 = 3

// Re-export all generated modules
pub mod crypto;
pub mod daemon;
pub mod discovery;
pub mod gf16;
pub mod modem;
pub mod router;
pub mod routing;
pub mod wire;

// Re-export generated mesh components
// Generated code is linted at its source (the .t27 spec), not here: t27c emits
// explicit returns, parenthesised expressions and unread initialisers by design,
// and rewriting them in gen/rust/ would break the spec-first invariant.
#[allow(clippy::all, unused)]
#[rustfmt::skip]
#[path = "../gen/rust/mesh_routing.rs"]
pub mod mesh_routing;

#[allow(clippy::all, unused)]
#[rustfmt::skip]
#[path = "../gen/rust/etx.rs"]
pub mod etx;

#[allow(clippy::all, unused)]
#[rustfmt::skip]
#[path = "../gen/rust/adaptive_routing.rs"]
pub mod adaptive_routing;

#[allow(clippy::all, unused)]
#[rustfmt::skip]
#[path = "../gen/rust/multipath_routing.rs"]
pub mod multipath_routing;

#[allow(clippy::all, unused)]
#[rustfmt::skip]
#[path = "../gen/rust/frame_buffer.rs"]
pub mod frame_buffer;

#[allow(clippy::all, unused)]
#[rustfmt::skip]
#[path = "../gen/rust/flow_control.rs"]
pub mod flow_control;

#[allow(clippy::all, unused)]
#[rustfmt::skip]
#[path = "../gen/rust/health_dashboard.rs"]
pub mod health_dashboard;

#[allow(clippy::all, unused)]
#[rustfmt::skip]
#[path = "../gen/rust/anomaly_detector.rs"]
pub mod anomaly_detector;

#[allow(clippy::all, unused)]
#[rustfmt::skip]
#[path = "../gen/rust/quarantine_manager.rs"]
pub mod quarantine_manager;

#[allow(clippy::all, unused)]
#[rustfmt::skip]
#[path = "../gen/rust/internet_call.rs"]
pub mod internet_call;

#[allow(clippy::all, unused)]
#[rustfmt::skip]
#[path = "../gen/rust/mesh_call_signaling.rs"]
pub mod mesh_call_signaling;

#[allow(clippy::all, unused)]
#[rustfmt::skip]
#[path = "../gen/rust/nickname_directory.rs"]
pub mod nickname_directory;

#[allow(clippy::all, unused)]
#[rustfmt::skip]
#[path = "../gen/rust/group_chat.rs"]
pub mod group_chat;

// Crate-root re-exports used by the binaries.
pub use crypto::{Handshake, MeshError};
pub use daemon::Node;

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
