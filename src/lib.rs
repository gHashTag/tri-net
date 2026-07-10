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

// Re-export generated mesh components. Produced from specs/*.t27 by t27c (golden
// pipeline) and kept byte-in-sync by the pinned-t27c drift-guard (see
// .t27c-version + .github/workflows/spec-drift-guard.yml).
//
// WIRED. These 9 modules now compile: the pinned t27c (fix commit d7f3a73 =
// gHashTag/t27 #1456 optimizer removal + #1457 array/index codegen) generates
// correct Rust, and the source specs had their genuine bugs fixed (path_valid
// typo, is_multipath_viable bool return, etx Q8.8 width, reassigned let -> var;
// see gHashTag/tri-net#61). They have zero call sites yet, so each carries an
// `#[allow(...)]` for dead-code/unused lints on generated theater. See
// docs/PIPELINE.md.
//
#[allow(dead_code, unused, unused_parens, clippy::all)]
#[path = "../gen/rust/mesh_routing.rs"]
pub mod mesh_routing;
#[allow(dead_code, unused, unused_parens, clippy::all)]
#[path = "../gen/rust/etx.rs"]
pub mod etx;
#[allow(dead_code, unused, unused_parens, clippy::all)]
#[path = "../gen/rust/adaptive_routing.rs"]
pub mod adaptive_routing;
#[allow(dead_code, unused, unused_parens, clippy::all)]
#[path = "../gen/rust/multipath_routing.rs"]
pub mod multipath_routing;
#[allow(dead_code, unused, unused_parens, clippy::all)]
#[path = "../gen/rust/frame_buffer.rs"]
pub mod frame_buffer;
#[allow(dead_code, unused, unused_parens, clippy::all)]
#[path = "../gen/rust/flow_control.rs"]
pub mod flow_control;
#[allow(dead_code, unused, unused_parens, clippy::all)]
#[path = "../gen/rust/health_dashboard.rs"]
pub mod health_dashboard;
#[allow(dead_code, unused, unused_parens, clippy::all)]
#[path = "../gen/rust/anomaly_detector.rs"]
pub mod anomaly_detector;
#[allow(dead_code, unused, unused_parens, clippy::all)]
#[path = "../gen/rust/quarantine_manager.rs"]
pub mod quarantine_manager;

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
