//! # trios-mesh
//!
//! TRI-NET drone-mesh daemon core: encrypted, self-routing IP-over-radio for the
//! P201/P203 **Zynq-7020 Mini** node ("Starlink without satellites"). Anchor: φ² + φ⁻² = 3.
//!
//! ## Milestones
//! - **M1** — X25519 handshake + ChaCha20-Poly1305 AEAD on a real ARM node ([`crypto`]).
//! - **M2** — TUN/netdev IP-over-radio with a real ETX metric ([`routing`], [`daemon`]).
//! - **M3** — iperf3 over 2 hops through attenuators.
//! - **M4** — share one uplink across a 3-node triangle.
//! - **M5** — self-healing re-route with a measured convergence time.
//!
//! Everything here is host-testable today (`-sim`); it graduates to `hw` once it
//! runs on the physical Mini node (its FPGA/PS was never flashed as of 2026-07-01).
#![forbid(unsafe_code)]

pub mod crypto;
pub mod daemon;
pub mod discovery;
pub mod gf16;
pub mod modem;
pub mod router;
pub mod routing;
pub mod wire;

pub use crypto::{public_from_bytes, Handshake, MeshError, Session, StaticKey};
pub use daemon::{Node, Transport};
pub use discovery::Hello;
pub use gf16::{equalize, fft, phi_dot, phi_fma, CGf16, Gf16};
pub use modem::{demodulate, modulate, rx_recover, tx_shaped, ModemTransport};
pub use router::{mesh_ip, node_of, Delivery, DropReason, MeshRouter, DEFAULT_TTL};
pub use routing::{EtxTable, NodeId};
pub use wire::{FrameKind, Header};
