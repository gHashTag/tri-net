//! HELLO beacons: each node periodically announces itself and the neighbors it
//! currently hears, which lets peers compute the *forward* delivery ratio for ETX.

use crate::routing::NodeId;

/// A HELLO beacon: `[src:4][seq:4][n:1][heard: n × 4]` (all big-endian).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hello {
    pub src: NodeId,
    pub seq: u32,
    /// Neighbors this node currently hears (so they learn their forward link).
    pub heard: Vec<NodeId>,
}

impl Hello {
    pub fn new(src: NodeId, seq: u32, heard: Vec<NodeId>) -> Self {
        Self { src, seq, heard }
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        let n = self.heard.len().min(u8::MAX as usize);
        let mut b = Vec::with_capacity(9 + n * 4);
        b.extend_from_slice(&self.src.to_be_bytes());
        b.extend_from_slice(&self.seq.to_be_bytes());
        b.push(n as u8);
        for id in self.heard.iter().take(n) {
            b.extend_from_slice(&id.to_be_bytes());
        }
        b
    }

    pub fn parse(b: &[u8]) -> Option<Self> {
        if b.len() < 9 {
            return None;
        }
        let src = u32::from_be_bytes(b[0..4].try_into().ok()?);
        let seq = u32::from_be_bytes(b[4..8].try_into().ok()?);
        let n = b[8] as usize;
        if b.len() < 9 + n * 4 {
            return None;
        }
        let mut heard = Vec::with_capacity(n);
        for i in 0..n {
            let off = 9 + i * 4;
            heard.push(u32::from_be_bytes(b[off..off + 4].try_into().ok()?));
        }
        Some(Self { src, seq, heard })
    }

    /// Did this beacon report hearing `me`? (⇒ our forward link to `src` is up.)
    pub fn reports_hearing(&self, me: NodeId) -> bool {
        self.heard.contains(&me)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hello_roundtrips() {
        let h = Hello::new(7, 42, vec![1, 2, 3]);
        assert_eq!(Hello::parse(&h.to_bytes()), Some(h));
    }

    #[test]
    fn empty_heard_list_ok() {
        let h = Hello::new(9, 1, vec![]);
        let p = Hello::parse(&h.to_bytes()).unwrap();
        assert!(p.heard.is_empty());
        assert!(!p.reports_hearing(5));
    }

    #[test]
    fn truncated_is_rejected() {
        let mut b = Hello::new(1, 1, vec![2, 3]).to_bytes();
        b.truncate(b.len() - 1);
        assert!(Hello::parse(&b).is_none());
    }
}
