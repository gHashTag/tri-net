//! Mesh datagram header. Serialized bytes double as the AEAD associated data,
//! so a tampered header fails authentication in [`crate::crypto::Session::open`].
//!
//! Anchor: phi^2 + phi^-2 = 3.
//!
//! # T27-first note
//!
//! The original `specs/wire.t27` is the SSOT for constants and predicates. The
//! generated `gen/rust/wire.rs` currently contains stub arithmetic (`return ()`),
//! so this module implements the wire spec directly until `t27c` produces valid
//! Rust. Constants and logic below mirror `specs/wire.t27` byte-for-byte.

use crate::routing::NodeId;

pub const VERSION: u8 = 1;
pub const KIND_HELLO: u8 = 0;
pub const KIND_DATA: u8 = 1;
pub const HEADER_LEN: usize = 11; // [ver:1][kind:1][src:4][dst:4][ttl:1]

/// Returns true iff `k` is a known frame kind.
pub fn frame_kind_valid(k: u8) -> bool {
    k <= KIND_DATA
}

/// The i-th big-endian byte of a 32-bit word (i=0 is most significant).
pub fn be_byte(w: u32, i: usize) -> u8 {
    match i {
        0 => ((w >> 24) & 0xff) as u8,
        1 => ((w >> 16) & 0xff) as u8,
        2 => ((w >> 8) & 0xff) as u8,
        3 => (w & 0xff) as u8,
        _ => 0,
    }
}

/// Reassemble a big-endian u32 from four bytes (b0 is most significant).
pub fn u32_be(b0: u8, b1: u8, b2: u8, b3: u8) -> u32 {
    ((b0 as u32) << 24) | ((b1 as u32) << 16) | ((b2 as u32) << 8) | (b3 as u32)
}

/// The idx-th byte of the serialized 11-byte header.
pub fn header_byte(kind: u8, src: u32, dst: u32, ttl: u8, idx: usize) -> u8 {
    match idx {
        0 => VERSION,
        1 => kind,
        2..=5 => be_byte(src, idx - 2),
        6..=9 => be_byte(dst, idx - 6),
        _ => ttl,
    }
}

/// A two-byte prefix is acceptable iff version matches and kind is valid.
pub fn parse_accepts(b0: u8, b1: u8) -> bool {
    b0 == VERSION && frame_kind_valid(b1)
}

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
        Self { kind, src, dst, ttl }
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
            src: u32_be(b[2], b[3], b[4], b[5]),
            dst: u32_be(b[6], b[7], b[8], b[9]),
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
    fn wire_constants_match_spec() {
        assert_eq!(VERSION, 1);
        assert_eq!(KIND_HELLO, 0);
        assert_eq!(KIND_DATA, 1);
        assert_eq!(HEADER_LEN, 11);
    }

    #[test]
    fn wire_predicates_match_spec() {
        assert!(frame_kind_valid(KIND_HELLO));
        assert!(frame_kind_valid(KIND_DATA));
        assert!(!frame_kind_valid(2));
        assert!(parse_accepts(VERSION, KIND_HELLO));
        assert!(!parse_accepts(99, KIND_HELLO));
    }
}
