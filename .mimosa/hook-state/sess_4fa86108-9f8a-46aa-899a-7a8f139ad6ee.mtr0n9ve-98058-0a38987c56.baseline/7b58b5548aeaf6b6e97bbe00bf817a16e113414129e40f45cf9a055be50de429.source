//! fec_ilv_burst_recovery -- the PHY error-resilience capstone: the interleaver (tri_ilv) and the
//! single-erasure XOR-FEC (tri_fec) are guarded separately (ilv_interleaver, video_bridge_wire), but
//! nothing pinned that they COMPOSE to survive a real burst. FEC recovers <=1 loss per codeword;
//! interleaving spreads a fading burst across codewords so each takes <=1 loss. This drives a whole
//! block through interleave -> a consecutive-transmit-position burst -> de-interleave -> FEC recover,
//! and proves: a burst of length <= depth is FULLY recovered, while the SAME burst WITHOUT
//! interleaving wipes >=2 datagrams of one codeword and is unrecoverable -- exactly why the
//! interleaver exists.

const W: u32 = 4; // FEC codeword width == K=4 group

// ---- tri_fec (K=4 single-erasure XOR) ----
fn fec_parity4(a: u32, b: u32, c: u32, d: u32) -> u32 {
    a ^ b ^ c ^ d
}
fn fec_recover(parity: u32, survivors_xor: u32) -> u32 {
    parity ^ survivors_xor
}

// ---- tri_ilv (block interleaver) ----
fn ilv_orig(t: u32, depth: u32, width: u32) -> u32 {
    (t % depth) * width + t / depth
}

/// A D x W block of data words plus one parity word per row (codeword).
struct Block {
    depth: u32,
    data: Vec<u32>,   // depth*W words, row-major: data[row*W + col]
    parity: Vec<u32>, // one per row
}
impl Block {
    fn new(depth: u32) -> Self {
        // A distinct value per cell so a wrong recovery is visible.
        let data: Vec<u32> = (0..depth * W)
            .map(|o| 0x1000_0000 ^ (o.wrapping_mul(0x9E37_79B9)))
            .collect();
        let parity: Vec<u32> = (0..depth)
            .map(|r| {
                let b = (r * W) as usize;
                fec_parity4(data[b], data[b + 1], data[b + 2], data[b + 3])
            })
            .collect();
        Block {
            depth,
            data,
            parity,
        }
    }

    /// Recover a block given the set of LOST original indices. Returns Some(recovered_data) if every
    /// codeword had <=1 loss (recoverable), None if any codeword lost >=2 (unrecoverable).
    fn recover(&self, lost: &[bool]) -> Option<Vec<u32>> {
        let mut out = self.data.clone();
        for row in 0..self.depth {
            let base = (row * W) as usize;
            let missing: Vec<usize> = (0..W as usize).filter(|&c| lost[base + c]).collect();
            match missing.len() {
                0 => {}
                1 => {
                    let c = missing[0];
                    // survivors XOR = XOR of the 3 present data words; recovered = parity ^ that.
                    let mut sx = 0u32;
                    for cc in 0..W as usize {
                        if cc != c {
                            sx ^= self.data[base + cc];
                        }
                    }
                    out[base + c] = fec_recover(self.parity[row as usize], sx);
                }
                _ => return None, // >=2 losses in one codeword: unrecoverable
            }
        }
        Some(out)
    }
}

/// Mark the original indices hit by an INTERLEAVED burst of `burst` consecutive transmit positions
/// starting at `start` (the transmit-order slots a fade corrupts).
fn interleaved_burst_losses(depth: u32, start: u32, burst: u32) -> Vec<bool> {
    let mut lost = vec![false; (depth * W) as usize];
    for k in 0..burst {
        let t = start + k;
        lost[ilv_orig(t, depth, W) as usize] = true;
    }
    lost
}

/// Mark the original indices hit by the SAME-length burst with NO interleaving (consecutive
/// ORIGINAL datagrams corrupted -- what happens if you skip the interleaver).
fn plain_burst_losses(depth: u32, start: u32, burst: u32) -> Vec<bool> {
    let mut lost = vec![false; (depth * W) as usize];
    for k in 0..burst {
        lost[((start + k) % (depth * W)) as usize] = true;
    }
    lost
}

#[test]
fn an_interleaved_burst_up_to_depth_is_fully_recovered() {
    for depth in [4u32, 8, 16] {
        let blk = Block::new(depth);
        let n = depth * W;
        for start in 0..n {
            let burst = depth.min(n - start); // up to one full column
            let lost = interleaved_burst_losses(depth, start, burst);
            let recovered = blk.recover(&lost).unwrap_or_else(|| {
                panic!("interleaved burst was unrecoverable: D={depth} start={start}")
            });
            assert_eq!(
                recovered, blk.data,
                "recovered block must equal the original (D={depth} start={start})"
            );
        }
    }
}

#[test]
fn the_same_burst_without_interleaving_is_unrecoverable() {
    // A burst of W consecutive ORIGINAL datagrams falls entirely inside one or two codewords, putting
    // >=2 losses in a codeword -> FEC cannot recover. This is the failure the interleaver prevents.
    let depth = 8u32;
    let blk = Block::new(depth);
    // A burst of length W=4 starting aligned to a row wipes an ENTIRE codeword (4 losses).
    let lost_aligned = plain_burst_losses(depth, 0, W);
    assert!(
        blk.recover(&lost_aligned).is_none(),
        "a plain burst over a whole codeword is unrecoverable"
    );
    // Even a burst of just 2 adjacent originals in the same row is already >=2 losses -> unrecoverable.
    let lost_pair = plain_burst_losses(depth, 0, 2);
    assert!(
        blk.recover(&lost_pair).is_none(),
        "2 adjacent originals in one codeword: unrecoverable"
    );
}

#[test]
fn a_burst_longer_than_depth_overflows_a_codeword_even_interleaved() {
    // Honest boundary: interleaving only survives bursts up to `depth`. A burst of depth+1 wraps to a
    // second transmit in some codeword (two losses there) -> unrecoverable. This is why choose_depth
    // must pick depth >= the measured burst.
    let depth = 8u32;
    let blk = Block::new(depth);
    let lost = interleaved_burst_losses(depth, 0, depth + 1);
    assert!(
        blk.recover(&lost).is_none(),
        "a burst of depth+1 exceeds the interleaver's protection"
    );
}

#[test]
fn a_single_loss_anywhere_is_always_recovered() {
    // The FEC base case, exercised through the block: any one lost datagram is recovered exactly.
    let depth = 8u32;
    let blk = Block::new(depth);
    for o in 0..depth * W {
        let mut lost = vec![false; (depth * W) as usize];
        lost[o as usize] = true;
        let recovered = blk.recover(&lost).expect("single loss is recoverable");
        assert_eq!(
            recovered[o as usize], blk.data[o as usize],
            "recovered the one lost word at {o}"
        );
        assert_eq!(recovered, blk.data, "and left the rest untouched");
    }
}
