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

// Re-export generated mesh components.
//
// TEMPORARILY UNWIRED (2026-07-10, wave-report branch): the t27c Rust emitter
// regressed at commit f608dad and regenerated these 9 modules with invalid Rust
// (dropped `let`/cast statements -> `let;`, `return ();` in `-> u8` fns), which
// broke `cargo build` on every clean clone since 2026-07-07. All 9 have ZERO
// call sites in src/ or the binaries (verified: `grep -rn '<mod>::' src`), so
// they are re-export theater — unwiring them restores a green build + the 101
// hand-written tests without touching any live datapath. RE-WIRE only after the
// t27c emitter fix (PR #44) lands and `gen/rust/*.rs` are regenerated cleanly.
// Tracking: docs/WAVE_REPORT_2026-07-10.md P0.
//
// #[path = "../gen/rust/mesh_routing.rs"]       pub mod mesh_routing;
// #[path = "../gen/rust/etx.rs"]                pub mod etx;
// #[path = "../gen/rust/adaptive_routing.rs"]   pub mod adaptive_routing;
// #[path = "../gen/rust/multipath_routing.rs"]  pub mod multipath_routing;
// #[path = "../gen/rust/frame_buffer.rs"]       pub mod frame_buffer;
// #[path = "../gen/rust/flow_control.rs"]       pub mod flow_control;
// #[path = "../gen/rust/health_dashboard.rs"]   pub mod health_dashboard;
// #[path = "../gen/rust/anomaly_detector.rs"]   pub mod anomaly_detector;
// #[path = "../gen/rust/quarantine_manager.rs"] pub mod quarantine_manager;

// Re-export the real, hand-written module APIs at the crate root so binaries
// and downstream code resolve `trios_mesh::Delivery` etc. to the actual
// implementations. Every type below exists in a submodule; the crate root only
// re-exports. Earlier a set of empty root "shadow stubs" (a struct Delivery
// with no variants, a struct Hello with no parse/authenticated, a struct
// StaticKey with no from_seed, and a second Transport trait with send_to/
// recv_from) shadowed these real types and made the binaries and the M1 smoke
// harness uncompilable even though the real code was fine. Those stubs were dead
// (zero call sites in src/; router.rs and modem.rs already use daemon::Transport)
// and are removed. See docs/WAVE_REPORT_2026-07-10.md P0b.
pub use crypto::{Handshake, MeshError, Session, StaticKey};
pub use daemon::{Node, Transport};
pub use discovery::Hello;
pub use router::{Delivery, DropReason, MeshRouter};

// Types used across the crate
pub type NodeId = u32;
