//! crypto_frame_nonce -- CI guard for the nonce-uniqueness and rekey discipline of the
//! ChaCha20-Poly1305 frame layer (specs/crypto_frame.t27). A repeated nonce is CATASTROPHIC for
//! ChaCha20-Poly1305 (keystream reuse -> plaintext recovery AND forgery), so the layer must (a)
//! give every frame a unique 12-byte nonce [dir:1][epoch:4 BE][counter low-7 BE], (b) ensure the two
//! peers' directions differ so the same (epoch, counter) never collides across the link, and (c)
//! ratchet at a routine budget and HARD-REJECT before the counter could wrap. None of this had a CI
//! twin (crypto_frame_replay guarded the replay window; this guards the seal side). This transcribes
//! the nonce/rekey functions and pins nonce uniqueness plus the ratchet and hard-cap boundaries.

const REKEY_EVERY_FRAMES: u64 = 1_048_576; // 2^20
const REKEY_HARD_CAP: u64 = 16_777_216; // 2^24

fn should_ratchet(tx_counter: u64) -> bool {
    tx_counter >= REKEY_EVERY_FRAMES
}
fn must_reject(tx_counter: u64) -> bool {
    tx_counter >= REKEY_HARD_CAP
}
fn rx_dir(tx_dir: u8) -> u8 {
    1 - tx_dir
}
fn nonce_byte(dir: u8, epoch: u32, ctr: u64, i: u32) -> u32 {
    if i == 0 {
        dir as u32
    } else if i < 5 {
        // epoch big-endian: byte 1 is the most significant epoch byte.
        (epoch >> ((4 - i) * 8)) & 255
    } else {
        // bytes 5..11: low 7 bytes of the counter, big-endian.
        ((ctr >> ((11 - i) * 8)) & 255) as u32
    }
}
/// The full 12-byte nonce, reassembled from the per-byte layout.
fn nonce(dir: u8, epoch: u32, ctr: u64) -> [u32; 12] {
    let mut n = [0u32; 12];
    for (i, slot) in n.iter_mut().enumerate() {
        *slot = nonce_byte(dir, epoch, ctr, i as u32);
    }
    n
}

#[test]
fn the_ratchet_and_hard_cap_fire_exactly_at_their_boundaries() {
    assert!(
        !should_ratchet(REKEY_EVERY_FRAMES - 1),
        "one below the budget: no ratchet"
    );
    assert!(should_ratchet(REKEY_EVERY_FRAMES), "at the budget: ratchet");
    assert!(
        should_ratchet(REKEY_EVERY_FRAMES + 1),
        "past the budget: ratchet"
    );
    assert!(
        !must_reject(REKEY_HARD_CAP - 1),
        "one below the hard cap: still allowed"
    );
    assert!(
        must_reject(REKEY_HARD_CAP),
        "at the hard cap: REJECT (never reuse a nonce)"
    );
    // The ratchet fires strictly before the hard cap, so a rekey happens long before any wrap: a
    // counter that must_reject rejects has already been should_ratchet-ratcheted at 2^20.
    assert!(
        should_ratchet(REKEY_HARD_CAP - 1),
        "any counter near the cap has long since ratcheted"
    );
}

#[test]
fn the_nonce_layout_places_dir_epoch_and_counter_correctly() {
    // dir=1, epoch=0x0A0B0C0D, counter whose low 7 bytes are 01 02 03 04 05 06 07.
    let n = nonce(1, 0x0A0B_0C0D, 0x0001_0203_0405_0607);
    assert_eq!(n[0], 1, "byte 0 is the direction");
    assert_eq!(
        [n[1], n[2], n[3], n[4]],
        [0x0A, 0x0B, 0x0C, 0x0D],
        "epoch big-endian in bytes 1..4"
    );
    assert_eq!(
        [n[5], n[6], n[7], n[8], n[9], n[10], n[11]],
        [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07],
        "counter low-7 big-endian in bytes 5..11"
    );
}

#[test]
fn distinct_counters_in_an_epoch_get_distinct_nonces() {
    // The core anti-reuse property: within one direction and epoch, every counter yields a unique
    // nonce. Sweep a run of counters and assert no two produce the same 12-byte nonce.
    use std::collections::HashSet;
    let mut seen: HashSet<[u32; 12]> = HashSet::new();
    for ctr in 0..5000u64 {
        assert!(
            seen.insert(nonce(0, 42, ctr)),
            "counter {ctr} reused a nonce"
        );
    }
    // A jump near the hard cap also stays unique (7-byte counter field never truncates below 2^24).
    for ctr in (REKEY_HARD_CAP - 2000)..REKEY_HARD_CAP {
        assert!(
            seen.insert(nonce(0, 42, ctr)),
            "high counter {ctr} reused a nonce"
        );
    }
}

#[test]
fn the_two_directions_never_collide_on_the_same_counter() {
    // rx_dir inverts the local tx dir, so the two peers use different direction bytes -- the SAME
    // (epoch, counter) on each side produces DIFFERENT nonces. This is what lets both peers count
    // from 0 in the same epoch without ever sharing a nonce.
    assert_eq!(rx_dir(0), 1, "rx inverts tx=0");
    assert_eq!(rx_dir(1), 0, "rx inverts tx=1");
    for &(epoch, ctr) in &[(0u32, 0u64), (42, 100), (7, REKEY_HARD_CAP - 1)] {
        let tx = nonce(0, epoch, ctr);
        let rx = nonce(rx_dir(0), epoch, ctr);
        assert_ne!(
            tx, rx,
            "same (epoch,ctr) on opposite directions must differ (epoch={epoch} ctr={ctr})"
        );
        assert_eq!(tx[0], 0, "tx dir byte");
        assert_eq!(rx[0], 1, "rx dir byte differs");
    }
}

#[test]
fn a_new_epoch_changes_the_nonce_so_a_reset_counter_is_still_unique() {
    // After a ratchet the epoch advances and the counter resets; the new epoch bytes keep the nonce
    // distinct from the old epoch's same-counter nonce, so counter reuse across epochs is safe.
    let old = nonce(0, 42, 0);
    let new = nonce(0, 43, 0);
    assert_ne!(
        old, new,
        "same dir+counter but a new epoch yields a different nonce"
    );
    assert_eq!(
        [new[1], new[2], new[3], new[4]],
        [0, 0, 0, 43],
        "epoch 43 big-endian"
    );
}
