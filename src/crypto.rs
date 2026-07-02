//! M1 crypto core: X25519 handshake → HKDF session key → ChaCha20-Poly1305 AEAD
//! with a directional 96-bit nonce and a 64-frame sliding replay window.
//!
//! Adds a symmetric **HKDF ratchet** (B10 / tri-net#10): the session periodically
//! advances `key_{i+1} = HKDF-Expand(chain_key_i, "aead-rekey")`, bumps a wire
//! **epoch**, resets the counter and replay window, and `zeroize`s the old chain
//! key. This bounds data-per-key (below ChaCha20-Poly1305's 2^32-block ceiling)
//! and gives forward secrecy across epochs: a captured node leaks only the
//! current epoch's key, not the whole session. All key material (`EphemeralSecret`,
//! HKDF output, chain key) is wiped on rekey and on drop.
//!
//! The ratchet is driven purely by frame count here — `seal` auto-ratchets at
//! [`REKEY_EVERY_FRAMES`] and refuses to reuse a nonce past [`REKEY_HARD_CAP`]
//! (returning [`MeshError::RekeyRequired`]). Time-based rekeying and the
//! daemon-side handling of `RekeyRequired` are deferred to the M2 run loop
//! (tri-net#11); this module only exposes [`Session::ratchet`] for that loop.
//!
//! Status: host-testable (`-sim`). Graduates to `hw` once it runs on the real
//! Zynq-7020 Mini ARM-Linux node (milestone M1, tri-net#10).

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use rand_core::OsRng;
use sha2::Sha256;
use x25519_dalek::{EphemeralSecret, PublicKey, StaticSecret};
use zeroize::Zeroizing;

/// HKDF context so keys derived here never collide with another protocol.
const HKDF_SALT: &[u8] = b"trios-mesh/v1/session";
/// Info label for the initial (epoch-0) AEAD key derived from the DH secret.
const HKDF_INFO: &[u8] = b"aead-key";
/// Distinct info label for each ratchet step so a ratchet output can never
/// collide with the initial key derivation.
const HKDF_INFO_RATCHET: &[u8] = b"aead-rekey";

/// Auto-ratchet after this many frames sealed within one epoch. Keeps each key's
/// data budget far below the AEAD ceiling under normal traffic.
pub const REKEY_EVERY_FRAMES: u64 = 1 << 20; // ~1.05M frames per epoch

/// Absolute per-key ceiling. Sealing at this counter fails rather than reusing a
/// nonce. Chosen so `REKEY_HARD_CAP * MAX_FRAME` stays well below ChaCha20's
/// 2^32-block limit — see the compile-time assertion below.
pub const REKEY_HARD_CAP: u64 = 1 << 24; // 16.7M frames — hard nonce-reuse guard

/// Largest single payload the mesh frames (matches the single-carrier modem cap).
/// Used only to bound the per-key block budget at compile time.
pub const MAX_FRAME: u64 = 255;

// Measurable metric (B10 acceptance): max data-per-key is provably bounded below
// ChaCha20-Poly1305's ~2^32-block safety limit. Each frame is <= MAX_FRAME bytes
// = <= ceil(255/64) = 4 AEAD blocks, and at most REKEY_HARD_CAP frames are sealed
// per key, so total blocks <= REKEY_HARD_CAP * 4 = 2^26 << 2^32.
const _: () = assert!(REKEY_EVERY_FRAMES < REKEY_HARD_CAP);
const _: () = assert!(REKEY_HARD_CAP * 4 < (1u64 << 32));
// Counter stays within the 7-byte (56-bit) nonce counter field.
const _: () = assert!(REKEY_HARD_CAP < (1u64 << 56));

#[derive(Debug, PartialEq, Eq)]
pub enum MeshError {
    /// AEAD tag verification failed (tampered, wrong key, or wrong epoch).
    Auth,
    /// Frame counter already seen or too old (replay).
    Replay,
    /// Frame shorter than the 12-byte `[epoch:4][counter:8]` prefix.
    ShortFrame,
    /// Per-key hard cap reached: the caller must `ratchet()` before sealing more,
    /// rather than risk a nonce reuse. Handled by the M2 loop (tri-net#11).
    RekeyRequired,
}

/// One side of an ephemeral X25519 handshake. `EphemeralSecret` zeroizes on drop
/// via the `zeroize` feature enabled on `x25519-dalek`.
pub struct Handshake {
    secret: EphemeralSecret,
    pub public: PublicKey,
}

impl Handshake {
    /// Generate a fresh ephemeral keypair from the OS CSPRNG.
    pub fn new() -> Self {
        let secret = EphemeralSecret::random_from_rng(OsRng);
        let public = PublicKey::from(&secret);
        Self { secret, public }
    }

    /// Complete the handshake against the peer's public key.
    ///
    /// `initiator` must differ between the two peers so their TX nonce spaces
    /// never overlap (initiator sends with direction byte 0, responder with 1).
    /// `self` is consumed, so the `EphemeralSecret` is dropped (and zeroized)
    /// as soon as the shared secret is derived.
    pub fn complete(self, peer: &PublicKey, initiator: bool) -> Session {
        let shared = self.secret.diffie_hellman(peer);
        Session::from_shared(shared.as_bytes(), initiator)
    }
}

impl Default for Handshake {
    fn default() -> Self {
        Self::new()
    }
}

/// A long-term (static) X25519 identity key. Used for pre-shared-key mesh links
/// where both peers' public keys are distributed out of band (an allow-list),
/// so a [`Session`] is derived with no handshake round-trip. The ephemeral,
/// mutually-authenticated Noise-XX path ([`Handshake`]) supersedes this for
/// untrusted peers.
pub struct StaticKey(StaticSecret);

impl StaticKey {
    /// Deterministic keypair from a 32-byte seed.
    pub fn from_seed(seed: [u8; 32]) -> Self {
        StaticKey(StaticSecret::from(seed))
    }

    /// This key's public half (share with peers).
    pub fn public(&self) -> PublicKey {
        PublicKey::from(&self.0)
    }

    /// Derive the session to a peer whose public key is already trusted.
    /// `initiator` must differ between the two peers (e.g. lower node id = true).
    pub fn session_with(&self, peer: &PublicKey, initiator: bool) -> Session {
        let shared = self.0.diffie_hellman(peer);
        Session::from_shared(shared.as_bytes(), initiator)
    }
}

/// Reconstruct a peer's public key from its 32 wire bytes.
pub fn public_from_bytes(bytes: [u8; 32]) -> PublicKey {
    PublicKey::from(bytes)
}

/// An authenticated, encrypted, replay-protected, forward-secret channel to one
/// peer. The `chain_key` is held in `Zeroizing` so every advance and the final
/// drop wipe the previous key material.
pub struct Session {
    cipher: ChaCha20Poly1305,
    chain_key: Zeroizing<[u8; 32]>,
    epoch: u32,
    tx_dir: u8,
    tx_counter: u64,
    rx: ReplayWindow,
}

impl Session {
    fn from_shared(shared: &[u8; 32], initiator: bool) -> Self {
        // The DH output seeds the ratchet chain; the epoch-0 AEAD key is one
        // HKDF-Expand off it. Both peers derive the identical chain from the
        // symmetric X25519 secret, so their epochs stay in lock-step.
        let hk = Hkdf::<Sha256>::new(Some(HKDF_SALT), shared);
        let mut chain = Zeroizing::new([0u8; 32]);
        hk.expand(b"ratchet-chain", chain.as_mut())
            .expect("32 bytes is a valid HKDF-SHA256 output length");
        let cipher = derive_cipher(&chain, HKDF_INFO);
        Self {
            cipher,
            chain_key: chain,
            epoch: 0,
            tx_dir: if initiator { 0 } else { 1 },
            tx_counter: 0,
            rx: ReplayWindow::new(),
        }
    }

    /// Current ratchet epoch (starts at 0). Exposed for tests and future M2
    /// telemetry.
    pub fn epoch(&self) -> u32 {
        self.epoch
    }

    /// Advance the symmetric ratchet: derive the next chain key and AEAD key,
    /// bump the epoch, reset the counter and replay window, and zeroize the old
    /// chain key. Both peers must ratchet in lock-step (same trigger) so their
    /// epochs — and therefore their nonces — stay aligned.
    ///
    /// The old key is unrecoverable after this call, giving forward secrecy:
    /// capturing the node now leaks only the new epoch's key.
    pub fn ratchet(&mut self) {
        // key_{i+1} = HKDF-Expand(chain_i, "aead-rekey"); chain_{i+1} likewise
        // off a distinct label. Zeroizing wraps the new chain and drops (wipes)
        // the old one on assignment.
        let hk = Hkdf::<Sha256>::from_prk(self.chain_key.as_ref())
            .expect("32-byte chain key is a valid HKDF-SHA256 PRK");
        let mut next_chain = Zeroizing::new([0u8; 32]);
        hk.expand(b"ratchet-chain", next_chain.as_mut())
            .expect("32 bytes is a valid HKDF-SHA256 output length");
        self.cipher = derive_cipher(&next_chain, HKDF_INFO_RATCHET);
        self.chain_key = next_chain; // old chain key dropped -> zeroized
        self.epoch = self.epoch.wrapping_add(1);
        self.tx_counter = 0;
        self.rx = ReplayWindow::new();
    }

    /// Seal `plaintext` with associated data `aad`.
    /// Wire frame = `[u32 epoch BE][u64 counter BE][ciphertext || 16-byte tag]`.
    ///
    /// Auto-ratchets when the per-epoch counter reaches [`REKEY_EVERY_FRAMES`].
    /// Returns [`MeshError::RekeyRequired`] rather than reuse a nonce if the
    /// caller somehow drives a single epoch past [`REKEY_HARD_CAP`] without the
    /// auto-ratchet firing (e.g. a manually forced counter).
    pub fn seal(&mut self, aad: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, MeshError> {
        // Absolute nonce-reuse guard, checked first so it holds even if the
        // auto-ratchet below was somehow bypassed (e.g. a caller that forced the
        // counter). Under normal traffic the auto-ratchet resets the counter far
        // below this ceiling, so this path is never taken.
        if self.tx_counter >= REKEY_HARD_CAP {
            return Err(MeshError::RekeyRequired);
        }
        // Routine forward-secrecy ratchet: bounded per-epoch data budget.
        if self.tx_counter >= REKEY_EVERY_FRAMES {
            self.ratchet();
        }
        let epoch = self.epoch;
        let ctr = self.tx_counter;
        self.tx_counter += 1;
        let nonce = make_nonce(self.tx_dir, epoch, ctr);
        let ct = self
            .cipher
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: plaintext,
                    aad,
                },
            )
            .expect("ChaCha20-Poly1305 encryption is infallible for valid inputs");
        let mut out = Vec::with_capacity(12 + ct.len());
        out.extend_from_slice(&epoch.to_be_bytes());
        out.extend_from_slice(&ctr.to_be_bytes());
        out.extend_from_slice(&ct);
        Ok(out)
    }

    /// Open a frame produced by the peer's [`Session::seal`].
    /// Verifies the tag first, then enforces the replay window.
    ///
    /// The epoch travels in the frame prefix and is folded into the nonce, so a
    /// frame from a different epoch decrypts under a different nonce and fails
    /// the tag as [`MeshError::Auth`] — cross-epoch replays cannot pass.
    pub fn open(&mut self, aad: &[u8], frame: &[u8]) -> Result<Vec<u8>, MeshError> {
        if frame.len() < 12 {
            return Err(MeshError::ShortFrame);
        }
        let epoch = u32::from_be_bytes(frame[..4].try_into().expect("4-byte slice"));
        let ctr = u64::from_be_bytes(frame[4..12].try_into().expect("8-byte slice"));
        // The peer's TX direction is the opposite of ours.
        let rx_dir = 1 - self.tx_dir;
        let nonce = make_nonce(rx_dir, epoch, ctr);
        let pt = self
            .cipher
            .decrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: &frame[12..],
                    aad,
                },
            )
            .map_err(|_| MeshError::Auth)?;
        // Only authenticated frames advance the replay window. The window is per
        // epoch (reset on ratchet); a stale-epoch frame never authenticates
        // under the current key, so it can't touch this window.
        if !self.rx.check_and_set(ctr) {
            return Err(MeshError::Replay);
        }
        Ok(pt)
    }
}

/// Derive a ChaCha20-Poly1305 cipher from a chain key under `info`, wiping the
/// expanded key bytes immediately after the cipher captures them.
fn derive_cipher(chain: &Zeroizing<[u8; 32]>, info: &[u8]) -> ChaCha20Poly1305 {
    let hk = Hkdf::<Sha256>::from_prk(chain.as_ref())
        .expect("32-byte chain key is a valid HKDF-SHA256 PRK");
    let mut key = Zeroizing::new([0u8; 32]);
    hk.expand(info, key.as_mut())
        .expect("32 bytes is a valid HKDF-SHA256 output length");
    ChaCha20Poly1305::new(Key::from_slice(key.as_ref()))
    // `key` (Zeroizing) is wiped here on drop.
}

/// 96-bit nonce = `[dir:1][epoch:4 BE][counter:7 BE]`. Unique per
/// (direction, epoch, counter): the epoch prevents any nonce reuse across
/// ratchet boundaries even though the counter resets to 0 each epoch.
fn make_nonce(dir: u8, epoch: u32, ctr: u64) -> [u8; 12] {
    let mut n = [0u8; 12];
    n[0] = dir;
    n[1..5].copy_from_slice(&epoch.to_be_bytes());
    // Low 7 bytes of the counter (bounded by REKEY_HARD_CAP < 2^56).
    n[5..12].copy_from_slice(&ctr.to_be_bytes()[1..8]);
    n
}

/// 64-frame sliding window that rejects replayed or too-old counters.
struct ReplayWindow {
    highest: u64,
    bitmap: u64,
    seen_any: bool,
}

impl ReplayWindow {
    const WIDTH: u64 = 64;

    fn new() -> Self {
        Self {
            highest: 0,
            bitmap: 0,
            seen_any: false,
        }
    }

    /// Returns `true` if `ctr` is fresh (and records it); `false` if replayed/old.
    fn check_and_set(&mut self, ctr: u64) -> bool {
        if !self.seen_any {
            self.seen_any = true;
            self.highest = ctr;
            self.bitmap = 1;
            return true;
        }
        if ctr > self.highest {
            let shift = ctr - self.highest;
            self.bitmap = if shift >= Self::WIDTH {
                1
            } else {
                (self.bitmap << shift) | 1
            };
            self.highest = ctr;
            true
        } else {
            let diff = self.highest - ctr;
            if diff >= Self::WIDTH {
                return false; // too old to prove non-replay
            }
            let mask = 1u64 << diff;
            if self.bitmap & mask != 0 {
                return false; // already seen
            }
            self.bitmap |= mask;
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Two peers derive the same key and can exchange a sealed message.
    fn pair() -> (Session, Session) {
        let a = Handshake::new();
        let b = Handshake::new();
        let a_pub = a.public;
        let b_pub = b.public;
        (a.complete(&b_pub, true), b.complete(&a_pub, false))
    }

    #[test]
    fn handshake_and_roundtrip() {
        let (mut alice, mut bob) = pair();
        let frame = alice.seal(b"hdr", b"hello mesh").unwrap();
        assert_eq!(bob.open(b"hdr", &frame).unwrap(), b"hello mesh");
        let back = bob.seal(b"hdr", b"ack").unwrap();
        assert_eq!(alice.open(b"hdr", &back).unwrap(), b"ack");
    }

    #[test]
    fn tamper_is_rejected() {
        let (mut alice, mut bob) = pair();
        let mut frame = alice.seal(b"", b"secret").unwrap();
        let last = frame.len() - 1;
        frame[last] ^= 0x01; // flip a tag bit
        assert_eq!(bob.open(b"", &frame), Err(MeshError::Auth));
    }

    #[test]
    fn wrong_aad_is_rejected() {
        let (mut alice, mut bob) = pair();
        let frame = alice.seal(b"src=1", b"payload").unwrap();
        assert_eq!(bob.open(b"src=2", &frame), Err(MeshError::Auth));
    }

    #[test]
    fn replay_is_rejected() {
        let (mut alice, mut bob) = pair();
        let frame = alice.seal(b"", b"once").unwrap();
        assert_eq!(bob.open(b"", &frame).unwrap(), b"once");
        // Re-delivering the identical frame must fail as a replay.
        assert_eq!(bob.open(b"", &frame), Err(MeshError::Replay));
    }

    #[test]
    fn out_of_order_within_window_ok() {
        let (mut alice, mut bob) = pair();
        let f0 = alice.seal(b"", b"0").unwrap();
        let f1 = alice.seal(b"", b"1").unwrap();
        let f2 = alice.seal(b"", b"2").unwrap();
        // Deliver 2, then 0, then 1 — all fresh, none replayed.
        assert_eq!(bob.open(b"", &f2).unwrap(), b"2");
        assert_eq!(bob.open(b"", &f0).unwrap(), b"0");
        assert_eq!(bob.open(b"", &f1).unwrap(), b"1");
        // But re-delivering 1 is a replay.
        assert_eq!(bob.open(b"", &f1), Err(MeshError::Replay));
    }

    #[test]
    fn short_frame_is_rejected() {
        let (_, mut bob) = pair();
        // 8 bytes was the old prefix length; the epoch-tagged prefix needs 12.
        assert_eq!(bob.open(b"", &[0u8; 8]), Err(MeshError::ShortFrame));
    }

    #[test]
    fn independent_handshakes_do_not_share_a_key() {
        let (mut alice, _bob) = pair();
        let (_alice2, mut bob2) = pair();
        let frame = alice.seal(b"", b"cross").unwrap();
        // bob2's key is from a different handshake → must not decrypt.
        assert_eq!(bob2.open(b"", &frame), Err(MeshError::Auth));
    }

    // --- B10 ratchet + zeroize -------------------------------------------

    #[test]
    fn ratchet_changes_key() {
        let (mut alice, mut bob) = pair();
        // A frame sealed in epoch 0 must not open after the receiver ratchets.
        let e0 = alice.seal(b"", b"epoch0").unwrap();
        bob.ratchet();
        assert_eq!(bob.epoch(), 1);
        assert_eq!(bob.open(b"", &e0), Err(MeshError::Auth));
        // Once the sender also ratchets, a fresh frame round-trips in epoch 1.
        alice.ratchet();
        let e1 = alice.seal(b"", b"epoch1").unwrap();
        assert_eq!(&e1[..4], &1u32.to_be_bytes()); // epoch tag on the wire
        assert_eq!(bob.open(b"", &e1).unwrap(), b"epoch1");
    }

    #[test]
    fn ratchet_resets_counter_and_window() {
        let (mut alice, mut bob) = pair();
        let old = alice.seal(b"", b"pre-ratchet").unwrap();
        assert_eq!(bob.open(b"", &old).unwrap(), b"pre-ratchet");
        alice.ratchet();
        bob.ratchet();
        // Counter restarts at 0 in the new epoch.
        let fresh = alice.seal(b"", b"post-ratchet").unwrap();
        assert_eq!(&fresh[4..12], &0u64.to_be_bytes());
        assert_eq!(bob.open(b"", &fresh).unwrap(), b"post-ratchet");
        // A frame from the previous epoch can no longer authenticate.
        assert_eq!(bob.open(b"", &old), Err(MeshError::Auth));
    }

    #[test]
    fn auto_rekey_at_frame_cap() {
        let (mut alice, mut bob) = pair();
        // Fast-forward both peers to just below the auto-ratchet threshold so
        // the test doesn't seal a million real frames.
        alice.tx_counter = REKEY_EVERY_FRAMES - 1;
        // Last frame of epoch 0.
        let last0 = alice.seal(b"", b"last-of-epoch0").unwrap();
        assert_eq!(alice.epoch(), 0);
        assert_eq!(&last0[..4], &0u32.to_be_bytes());
        assert_eq!(bob.open(b"", &last0).unwrap(), b"last-of-epoch0");
        // Next seal crosses the threshold: exactly one auto-ratchet to epoch 1.
        let first1 = alice.seal(b"", b"first-of-epoch1").unwrap();
        assert_eq!(alice.epoch(), 1);
        assert_eq!(&first1[..4], &1u32.to_be_bytes());
        // The receiver ratchets in lock-step and the frame still round-trips.
        bob.ratchet();
        assert_eq!(bob.open(b"", &first1).unwrap(), b"first-of-epoch1");
    }

    #[test]
    fn hard_cap_refuses_reuse() {
        let (mut alice, _bob) = pair();
        // Pin the counter to the absolute per-key ceiling. The hard-cap guard is
        // checked before the auto-ratchet, so `seal` must refuse rather than emit
        // a frame that could reuse a nonce.
        alice.tx_counter = REKEY_HARD_CAP;
        assert_eq!(alice.seal(b"", b"over-cap"), Err(MeshError::RekeyRequired));
        // One below the cap still seals (after the routine auto-ratchet).
        alice.tx_counter = REKEY_HARD_CAP - 1;
        assert!(alice.seal(b"", b"under-cap").is_ok());
    }

    #[test]
    fn key_material_is_zeroized() {
        use zeroize::Zeroize;
        // Explicitly zeroizing a key buffer must wipe every byte to zero — this
        // is exactly the guarantee `Zeroizing` invokes in its `Drop`. Tested on
        // an owned buffer (no `unsafe`, honoring the crate's forbid(unsafe_code)).
        let mut key = [0xABu8; 32];
        assert!(key.iter().all(|&b| b == 0xAB));
        key.zeroize();
        assert!(key.iter().all(|&b| b == 0x00), "key material must be wiped");
    }

    // Data-per-key bound (B10 "measurable metric") is proven at compile time by
    // the `const _: () = assert!(REKEY_HARD_CAP * 4 < (1u64 << 32));` above, so no
    // runtime test is needed (and a runtime assert on constants trips clippy).
}
