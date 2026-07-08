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
pub mod wire;
pub mod router;
pub mod routing;
pub mod modem;
pub mod gf16;
pub mod daemon;
pub mod discovery;

// Re-export generated mesh components
#[path = "../gen/rust/mesh_routing.rs"]
pub mod mesh_routing;

#[path = "../gen/rust/etx.rs"]
pub mod etx;

#[path = "../gen/rust/adaptive_routing.rs"]
pub mod adaptive_routing;

#[path = "../gen/rust/multipath_routing.rs"]
pub mod multipath_routing;

#[path = "../gen/rust/frame_buffer.rs"]
pub mod frame_buffer;

#[path = "../gen/rust/flow_control.rs"]
pub mod flow_control;

#[path = "../gen/rust/health_dashboard.rs"]
pub mod health_dashboard;

#[path = "../gen/rust/anomaly_detector.rs"]
pub mod anomaly_detector;

#[path = "../gen/rust/quarantine_manager.rs"]
pub mod quarantine_manager;

#[path = "../gen/rust/tun.rs"]
pub mod tun;

#[path = "../gen/rust/gateway.rs"]
pub mod gateway;

#[path = "../gen/rust/qos_scheduler.rs"]
pub mod qos_scheduler;

#[path = "../gen/rust/link_budget.rs"]
pub mod link_budget;

#[path = "../gen/rust/anon.rs"]
pub mod anon;

#[path = "../gen/rust/mesh_metrics.rs"]
pub mod mesh_metrics;

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
