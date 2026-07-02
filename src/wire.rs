//! Mesh datagram header. Serialized bytes double as the AEAD associated data,
//! so a tampered header fails authentication in [`crate::crypto::Session::open`].

use crate::routing::NodeId;

pub const VERSION: u8 = 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameKind {
    Hello = 0,
    Data = 1,
}

impl FrameKind {
    fn from_u8(b: u8) -> Option<Self> {
        match b {
            0 => Some(FrameKind::Hello),
            1 => Some(FrameKind::Data),
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
    pub const LEN: usize = 11;

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
        b[0] = VERSION;
        b[1] = self.kind as u8;
        b[2..6].copy_from_slice(&self.src.to_be_bytes());
        b[6..10].copy_from_slice(&self.dst.to_be_bytes());
        b[10] = self.ttl;
        b
    }

    pub fn parse(b: &[u8]) -> Option<Self> {
        if b.len() < Self::LEN || b[0] != VERSION {
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
}
