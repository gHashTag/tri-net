//! Mesh datagram header. Serialized bytes double as the AEAD associated data,
//! so a tampered header fails authentication in [`crate::crypto::Session::open`].
//!
//! Anchor: phi^2 + phi^-2 = 3.
//!
//! # T27-first partial flip
//!
//! Constants (`VERSION`, `KIND_HELLO`, `KIND_DATA`, `HEADER_LEN`) and pure
//! predicates (`frame_kind_valid`, `header_byte`, `parse_accepts`) live in
//! `specs/wire.t27` and are auto-generated into `gen/rust/wire.rs` via the
//! t27c bootstrap compiler. This module re-exports them and wraps them in
//! ergonomic Rust types. See `docs/T27_FIRST_MIGRATION.md`.

use crate::routing::NodeId;

// Auto-generated from specs/wire.t27 by t27c gen-rust.
pub mod gen {
    include!("../gen/rust/wire.rs");
}

pub use gen::{
    frame_kind_valid, header_byte, parse_accepts, HEADER_LEN, KIND_DATA, KIND_HELLO, VERSION,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameKind {
    Hello = KIND_HELLO as isize,
    Data = KIND_DATA as isize,
}

impl FrameKind {
    fn from_u8(b: u8) -> Option<Self> {
        if !frame_kind_valid(b) {
            return None;
        }
        match b {
            x if x == KIND_HELLO => Some(FrameKind::Hello),
            x if x == KIND_DATA => Some(FrameKind::Data),
            _ => None,
        }
    }
}

/// Fixed 11-byte header: `[ver:1][kind:1][src:4][dst:4][ttl:1]`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Header {
    pub kind: FrameKind,
    pub src: NodeId,
    pub dst: NodeId,
    pub ttl: u8,
}

impl Header {
    pub const LEN: usize = HEADER_LEN;

    pub fn new(kind: FrameKind, src: NodeId, dst: NodeId, ttl: u8) -> Self {
        Self {
            kind,
            src,
            dst,
            ttl,
        }
    }

    pub fn to_bytes(&self) -> [u8; Self::LEN] {
        let mut b = [0u8; Self::LEN];
        let kind = self.kind as u8;
        for (i, slot) in b.iter_mut().enumerate() {
            *slot = header_byte(kind, self.src, self.dst, self.ttl, i);
        }
        b
    }

    pub fn parse(b: &[u8]) -> Option<Self> {
        if b.len() < Self::LEN {
            return None;
        }
        if !parse_accepts(b[0], b[1]) {
            return None;
        }
        Some(Self {
            kind: FrameKind::from_u8(b[1])?,
            src: u32::from_be_bytes(b[2..6].try_into().ok()?),
            dst: u32::from_be_bytes(b[6..10].try_into().ok()?),
            ttl: b[10],
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_roundtrips() {
        let h = Header::new(FrameKind::Data, 0x0102_0304, 0x0a0b_0c0d, 8);
        assert_eq!(Header::parse(&h.to_bytes()), Some(h));
    }

    #[test]
    fn bad_version_rejected() {
        let mut b = Header::new(FrameKind::Hello, 1, 2, 4).to_bytes();
        b[0] = 99;
        assert!(Header::parse(&b).is_none());
    }

    #[test]
    fn t27_gen_constants_match_hand_written() {
        assert_eq!(VERSION, 1);
        assert_eq!(KIND_HELLO, 0);
        assert_eq!(KIND_DATA, 1);
        assert_eq!(HEADER_LEN, 11);
    }

    #[test]
    fn t27_gen_predicates_match_semantics() {
        assert!(frame_kind_valid(KIND_HELLO));
        assert!(frame_kind_valid(KIND_DATA));
        assert!(!frame_kind_valid(2));
        assert!(parse_accepts(VERSION, KIND_HELLO));
        assert!(!parse_accepts(99, KIND_HELLO));
    }
}
