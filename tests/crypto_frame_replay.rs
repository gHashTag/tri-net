//! crypto_frame_replay -- CI guard for the TRANSPORT anti-replay sliding window (specs/
//! crypto_frame.t27), the ChaCha20-Poly1305 frame layer's defense against a replayed encrypted
//! datagram. This is distinct from the settlement watermark (a2a_mesh_antireplay, tri_a2a): that
//! rejects a replayed RESULT by task_id; this rejects a replayed FRAME by its per-key counter. It is
//! a 64-bit RFC-style window (IPsec/DTLS anti-replay) split across two u32 lanes (blo/bhi) -- exactly
//! the code where off-by-one at the window edge or a lane-crossing shift error lets a duplicate slip
//! through. It had no CI twin. This transcribes the window functions, pins the spec KATs, and drives
//! a receiver over a sequence to prove the real property: no accepted counter is ever accepted twice.

const WINDOW_WIDTH: u64 = 64;

fn replay_accept(seen_any: bool, top: u64, blo: u32, bhi: u32, ctr: u64) -> bool {
    if !seen_any {
        return true;
    }
    if ctr > top {
        return true;
    }
    let d = top - ctr;
    if d >= WINDOW_WIDTH {
        return false; // too old to prove non-replay
    }
    if d < 32 {
        (blo & (1u32 << d)) == 0
    } else {
        (bhi & (1u32 << (d - 32))) == 0
    }
}
fn replay_next_top(seen_any: bool, top: u64, ctr: u64) -> u64 {
    if !seen_any || ctr > top {
        ctr
    } else {
        top
    }
}
fn replay_next_blo(seen_any: bool, top: u64, blo: u32, ctr: u64) -> u32 {
    if !seen_any {
        return 1; // first frame: bit 0
    }
    if ctr > top {
        let s = ctr - top;
        if s >= 32 {
            1
        } else {
            (blo << s) | 1
        }
    } else {
        let d = top - ctr;
        if d < 32 {
            blo | (1u32 << d)
        } else {
            blo
        }
    }
}
fn replay_next_bhi(seen_any: bool, top: u64, blo: u32, bhi: u32, ctr: u64) -> u32 {
    if !seen_any {
        return 0; // first frame lives in the low lane
    }
    if ctr > top {
        let s = ctr - top;
        if s >= WINDOW_WIDTH {
            0
        } else if s >= 32 {
            blo << (s - 32)
        } else {
            (bhi << s) | (blo >> (32 - s))
        }
    } else {
        let d = top - ctr;
        if d >= 32 {
            bhi | (1u32 << (d - 32))
        } else {
            bhi
        }
    }
}

#[test]
fn spec_kats_first_duplicate_lanes_too_old_and_forward_jump() {
    // first frame accepted, its bit recorded, immediate duplicate rejected.
    assert!(replay_accept(false, 0, 0, 0, 7), "first frame accepted");
    assert_eq!(replay_next_blo(false, 0, 0, 7), 1, "first frame sets bit 0");
    assert!(
        !replay_accept(true, 7, 1, 0, 7),
        "immediate duplicate rejected"
    );
    // in-window low lane: a gap-fill counter is fresh and sets its bit.
    assert!(
        replay_accept(true, 10, 1, 0, 5),
        "in-window gap-fill accepted"
    );
    assert_eq!(replay_next_blo(true, 10, 1, 5), 33, "bit 5 set -> 1|32");
    // in-window high lane (d in 32..64): the bit lives in bhi.
    assert!(
        replay_accept(true, 40, 1, 0, 5),
        "high-lane gap-fill accepted"
    );
    assert_eq!(replay_next_bhi(true, 40, 1, 0, 5), 8, "bit (35-32)=3 -> 8");
    // too old: beyond the 64-wide window, cannot prove non-replay -> rejected.
    assert!(
        !replay_accept(true, 70, 1, 0, 5),
        "d=65 >= WINDOW_WIDTH -> rejected"
    );
    // forward jump slides the window, carrying the low lane's set bits.
    assert_eq!(replay_next_blo(true, 5, 1, 8), 9, "blo << 3 | 1 = 9");
    assert_eq!(
        replay_next_bhi(true, 5, 1, 0, 8),
        0,
        "nothing carried into bhi yet"
    );
}

// A receiver's window state, driven exactly by the spec functions.
struct Window {
    seen_any: bool,
    top: u64,
    blo: u32,
    bhi: u32,
}
impl Window {
    fn new() -> Self {
        Window {
            seen_any: false,
            top: 0,
            blo: 0,
            bhi: 0,
        }
    }
    /// Try to receive a counter: accept-or-reject, and advance the window on accept.
    fn recv(&mut self, ctr: u64) -> bool {
        let ok = replay_accept(self.seen_any, self.top, self.blo, self.bhi, ctr);
        if ok {
            // Compute all three from the OLD state, then commit.
            let nblo = replay_next_blo(self.seen_any, self.top, self.blo, ctr);
            let nbhi = replay_next_bhi(self.seen_any, self.top, self.blo, self.bhi, ctr);
            let ntop = replay_next_top(self.seen_any, self.top, ctr);
            self.blo = nblo;
            self.bhi = nbhi;
            self.top = ntop;
            self.seen_any = true;
        }
        ok
    }
}

#[test]
fn no_accepted_counter_is_ever_accepted_twice() {
    // The anti-replay property, driven over a realistic out-of-order sequence: each fresh counter is
    // accepted once; re-presenting ANY already-accepted counter is rejected as a replay.
    let mut w = Window::new();
    let seq = [100u64, 101, 99, 98, 102, 150, 151, 149];
    for &c in &seq {
        assert!(w.recv(c), "fresh counter {c} accepted");
    }
    // Replay every one of them -- all rejected (still in the 64-wide window around top=151).
    for &c in &seq {
        assert!(!w.recv(c), "replayed counter {c} rejected");
    }
    // A brand-new higher counter is still accepted after all that.
    assert!(w.recv(160), "a genuinely new counter is accepted");
    assert!(!w.recv(160), "and immediately rejected on replay");
}

#[test]
fn a_forward_jump_past_the_window_reopens_old_slots_but_never_reaccepts_a_live_one() {
    // Jump far ahead: counters older than (top - 64) fall out of the window and are treated as
    // too-old (rejected), while the just-seen recent ones remain protected.
    let mut w = Window::new();
    assert!(w.recv(1000), "first");
    assert!(w.recv(1001), "next");
    assert!(w.recv(2000), "big forward jump accepted");
    // 1000/1001 are now > 64 behind top=2000 -> too old -> rejected (cannot prove non-replay).
    assert!(!w.recv(1000), "old counter beyond the window is rejected");
    assert!(
        !w.recv(2000),
        "the jump target itself is a duplicate -> rejected"
    );
    // A fresh in-window counter just behind the new top is still accepted once.
    assert!(w.recv(1990), "in-window gap-fill after the jump accepted");
    assert!(!w.recv(1990), "and rejected on replay");
}
