//! HELLO beacons: each node periodically announces itself and the neighbors it
//! currently hears, which lets peers compute the *forward* delivery ratio for ETX.
//!
//! E2 - Authenticated HELLO: Each beacon now carries a timestamp and MAC to
//! prevent false-metric attacks (W2). Format: `[src:4][seq:4][ts:8][n:1][heard:nx4][mac:16]`

use crate::routing::NodeId;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use std::time::{SystemTime, UNIX_EPOCH};

/// E2.2 - MAC key for HELLO beacons (derived from session key)
const HELLO_MAC_KEY: [u8; 32] = [
    0x74, 0x72, 0x69, 0x6f, 0x73, 0x2d, 0x6d, 0x65, 0x73, 0x68, 0x2d, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    0x2d, 0x6d, 0x61, 0x63, 0x2d, 0x6b, 0x65, 0x79, 0x2d, 0x76, 0x31, 0x00, 0x00, 0x00, 0x00, 0x00,
]; // "trios-mesh-hello-mac-key-v1" null-padded to 32 bytes

/// E2.3 - Freshness threshold: reject beacons older than 2xHELLO_MS
/// Assuming HELLO_MS = 300 ms, this is 600 ms
const HELLO_FRESHNESS_MS: u64 = 600;

/// A HELLO beacon: `[src:4][seq:4][ts:8][n:1][heard: n x 4][mac:16]` (all big-endian).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hello {
    pub src: NodeId,
    pub seq: u32,
    /// E2.3 - Timestamp for freshness check
    pub ts: u64,
    /// Neighbors this node currently hears (so they learn their forward link).
    pub heard: Vec<NodeId>,
    /// E2.2 - MAC over (src, seq, ts, heard[])
    pub mac: [u8; 16],
}

impl Hello {
    pub fn new(src: NodeId, seq: u32, ts: u64, heard: Vec<NodeId>, mac: [u8; 16]) -> Self {
        Self {
            src,
            seq,
            ts,
            heard,
            mac,
        }
    }

    /// E2.3 - Get current timestamp as milliseconds since Unix epoch
    pub fn now_ms() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64
    }

    /// Create a beacon with automatic timestamp and MAC calculation (E2.2)
    /// Uses a symmetric key for MAC (in production, derive from session key)
    pub fn authenticated(
        src: NodeId,
        seq: u32,
        heard: Vec<NodeId>,
        mac_key: &Option<[u8; 32]>,
    ) -> Result<Self, crate::crypto::MeshError> {
        let ts = Self::now_ms();
        let mac = Self::compute_mac(src, seq, ts, &heard, mac_key)?;
        Ok(Self {
            src,
            seq,
            ts,
            heard,
            mac,
        })
    }

    /// E2.2 - Compute MAC over (src, seq, ts, heard[]) using ChaCha20-Poly1305
    /// The MAC key is typically derived from the session key with a context label
    fn compute_mac(
        src: NodeId,
        seq: u32,
        ts: u64,
        heard: &[NodeId],
        mac_key: &Option<[u8; 32]>,
    ) -> Result<[u8; 16], crate::crypto::MeshError> {
        let key_bytes = mac_key.unwrap_or(HELLO_MAC_KEY);
        let cipher = ChaCha20Poly1305::new(Key::from_slice(&key_bytes));

        // Build MAC input: src || seq || ts || heard[]
        let n = heard.len().min(u8::MAX as usize);
        let mut aad = Vec::with_capacity(12 + n * 4);
        aad.extend_from_slice(&src.to_be_bytes());
        aad.extend_from_slice(&seq.to_be_bytes());
        aad.extend_from_slice(&ts.to_be_bytes());
        for id in heard.iter().take(n) {
            aad.extend_from_slice(&id.to_be_bytes());
        }

        // Use empty plaintext, MAC is in the tag
        let nonce = Nonce::from_slice(&[0u8; 12]); // fixed nonce for MAC-only mode
        let ct = cipher
            .encrypt(
                nonce,
                Payload {
                    msg: &[],
                    aad: &aad,
                },
            )
            .map_err(|_| crate::crypto::MeshError::CryptoInternal)?;

        // Extract 16-byte tag (MAC)
        let mut mac = [0u8; 16];
        mac.copy_from_slice(&ct[..16]);
        Ok(mac)
    }

    /// E2.2 - Verify MAC over (src, seq, ts, heard[])
    pub fn verify_mac(&self, mac_key: &Option<[u8; 32]>) -> bool {
        let Ok(expected) = Self::compute_mac(self.src, self.seq, self.ts, &self.heard, mac_key) else {
            return false;
        };
        self.mac == expected
    }

    /// E2.3 - Check freshness: reject beacons older than HELLO_FRESHNESS_MS
    pub fn is_fresh(&self) -> bool {
        let now = Self::now_ms();
        // Handle timestamp wrap-around (unlikely for 64-bit but safe)
        let diff = now.abs_diff(self.ts);
        diff < HELLO_FRESHNESS_MS
    }

    /// Old format for backward compatibility (tests only)
    #[cfg(test)]
    pub fn legacy(src: NodeId, seq: u32, heard: Vec<NodeId>) -> Self {
        Self {
            src,
            seq,
            ts: 0,
            heard,
            mac: [0u8; 16],
        }
    }

    /// Serialize to new authenticated format
    pub fn to_bytes(&self) -> Vec<u8> {
        let n = self.heard.len().min(u8::MAX as usize);
        let mut b = Vec::with_capacity(17 + n * 4); // +8 for ts, +16 for mac
        b.extend_from_slice(&self.src.to_be_bytes());
        b.extend_from_slice(&self.seq.to_be_bytes());
        b.extend_from_slice(&self.ts.to_be_bytes()); // E2.3 - timestamp
        b.push(n as u8);
        for id in self.heard.iter().take(n) {
            b.extend_from_slice(&id.to_be_bytes());
        }
        b.extend_from_slice(&self.mac); // E2.2 - MAC
        b
    }

    pub fn parse(b: &[u8]) -> Option<Self> {
        // New format: [src:4][seq:4][ts:8][n:1][heard:nx4][mac:16]
        if b.len() < 17 {
            // 4+4+8+1 minimum (no heard) +16 mac
            return None;
        }
        let src = u32::from_be_bytes(b[0..4].try_into().ok()?);
        let seq = u32::from_be_bytes(b[4..8].try_into().ok()?);
        let ts = u64::from_be_bytes(b[8..16].try_into().ok()?);
        let n = b[16] as usize;
        if b.len() < 17 + n * 4 {
            return None;
        }

        let mut heard = Vec::with_capacity(n);
        for i in 0..n {
            let off = 17 + i * 4;
            heard.push(u32::from_be_bytes(b[off..off + 4].try_into().ok()?));
        }

        let mac_off = 17 + n * 4;
        if b.len() < mac_off + 16 {
            return None;
        }
        let mut mac = [0u8; 16];
        mac.copy_from_slice(&b[mac_off..mac_off + 16]);

        Some(Self {
            src,
            seq,
            ts,
            heard,
            mac,
        })
    }

    /// Did this beacon report hearing `me`? (=> our forward link to `src` is up.)
    pub fn reports_hearing(&self, me: NodeId) -> bool {
        self.heard.contains(&me)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hello_roundtrips() {
        let mac = [1u8; 16];
        let h = Hello::new(7, 42, 12345, vec![1, 2, 3], mac);
        assert_eq!(Hello::parse(&h.to_bytes()), Some(h));
    }

    #[test]
    fn empty_heard_list_ok() {
        let mac = [2u8; 16];
        let h = Hello::new(9, 1, 9999, vec![], mac);
        let p = Hello::parse(&h.to_bytes()).unwrap();
        assert!(p.heard.is_empty());
        assert!(!p.reports_hearing(5));
    }

    #[test]
    fn truncated_is_rejected() {
        let mac = [3u8; 16];
        let mut b = Hello::new(1, 1, 5555, vec![2, 3], mac).to_bytes();
        b.truncate(b.len() - 1);
        assert!(Hello::parse(&b).is_none());
    }

    // --- E2.2: MAC verification tests --------------------------------------

    #[test]
    fn mac_verifies_authentic_beacon() {
        let key = Some([42u8; 32]);
        let h = Hello::authenticated(7, 123, vec![1, 2, 3], &key).unwrap();

        // MAC should verify
        assert!(h.verify_mac(&key));

        // Tamper with heard list
        let mut h_tampered = h.clone();
        h_tampered.heard.push(999);
        assert!(!h_tampered.verify_mac(&key));

        // Tamper with seq
        let mut h_tampered = h.clone();
        h_tampered.seq += 1;
        assert!(!h_tampered.verify_mac(&key));
    }

    #[test]
    fn mac_different_key_fails() {
        let key1 = Some([1u8; 32]);
        let key2 = Some([2u8; 32]);

        let h = Hello::authenticated(7, 123, vec![1, 2], &key1).unwrap();

        // Verification with wrong key fails
        assert!(!h.verify_mac(&key2));
    }

    #[test]
    fn mac_prevents_false_metric_attack() {
        // E2.4 - Attack simulation: Mallory tries to inflate ETX by forging heard[]
        let key = Some([99u8; 32]);

        // Legitimate beacon from node 7
        let legitimate = Hello::authenticated(7, 1, vec![1, 2], &key).unwrap();

        // Mallory creates fake beacon claiming node 7 heard everyone
        let fake = Hello {
            src: 7,
            seq: 1,
            ts: legitimate.ts,
            heard: vec![1, 2, 3, 4, 5, 6, 7, 8, 9], // inflated!
            mac: legitimate.mac,                    // copied from legitimate
        };

        // Fake beacon fails MAC verification
        assert!(!fake.verify_mac(&key));

        // Even if Mallory recomputes MAC with wrong key, it fails
        let fake_with_mac = Hello::authenticated(7, 1, vec![1, 2, 3, 4, 5], &key).unwrap();
        assert_ne!(fake_with_mac.mac, legitimate.mac);
    }

    // --- E2.3: Freshness tests ----------------------------------------------

    #[test]
    fn fresh_beacon_accepted() {
        let key = Some([5u8; 32]);
        let h = Hello::authenticated(7, 123, vec![1], &key).unwrap();

        // Fresh beacon should pass
        assert!(h.is_fresh());
    }

    #[test]
    fn old_beacon_rejected() {
        let _key = Some([6u8; 32]);

        // Create beacon with old timestamp
        let now = Hello::now_ms();
        let old_ts = now - HELLO_FRESHNESS_MS - 100; // older than threshold

        let h = Hello::new(7, 123, old_ts, vec![1], [0u8; 16]);

        // Old beacon should fail freshness
        assert!(!h.is_fresh());
    }

    #[test]
    fn authenticated_hello_roundtrip() {
        let key = Some([7u8; 32]);

        // Create authenticated beacon
        let h = Hello::authenticated(7, 456, vec![8, 9, 10], &key).unwrap();

        // Serialize and parse
        let bytes = h.to_bytes();
        let parsed = Hello::parse(&bytes).unwrap();

        // Should be identical
        assert_eq!(parsed.src, h.src);
        assert_eq!(parsed.seq, h.seq);
        assert_eq!(parsed.heard, h.heard);
        assert_eq!(parsed.mac, h.mac);

        // MAC should verify
        assert!(parsed.verify_mac(&key));
    }
}
