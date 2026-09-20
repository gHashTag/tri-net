//! ilv_interleaver -- CI guard for the radio-PHY block interleaver (specs/tri_ilv.t27), the layer
//! that lets the single-erasure XOR-FEC (tri_fec) survive a BURST of channel errors. FEC recovers at
//! most one lost datagram per codeword; the interleaver spreads a fading burst across codewords so a
//! burst of length <= depth leaves <=1 error per codeword. tri_fec is CI-guarded (video_bridge_wire),
//! but its companion interleaver was not. Two properties matter: the interleave/de-interleave is an
//! exact BIJECTION (no datagram lost or duplicated -- a permutation), and a burst of consecutive
//! transmit positions lands in DISTINCT codewords (so FEC can then recover it). This transcribes the
//! interleaver functions and pins both, plus the adaptive-depth choice.

const DEPTH_CAP: u32 = 64;

/// original (codeword-major) index -> transmit position: element o=(row=o/W, col=o%W) read col-major.
fn ilv_tx_pos(o: u32, depth: u32, width: u32) -> u32 {
    (o % width) * depth + o / width
}
/// transmit position -> original index (the inverse of ilv_tx_pos).
fn ilv_orig(t: u32, depth: u32, width: u32) -> u32 {
    (t % depth) * width + t / depth
}
fn ilv_codeword(o: u32, width: u32) -> u32 {
    o / width
}
fn choose_depth(max_burst: u32) -> u32 {
    if max_burst == 0 {
        1
    } else if max_burst >= DEPTH_CAP {
        DEPTH_CAP
    } else {
        max_burst
    }
}
fn depth_survives(depth: u32, burst: u32) -> bool {
    depth >= burst
}

// A few block geometries (depth x width) to sweep the properties over.
const GEOMS: [(u32, u32); 4] = [(8, 4), (16, 8), (4, 4), (7, 5)];

#[test]
fn interleave_then_deinterleave_is_the_identity_over_the_whole_block() {
    // Round-trip bijection: every original index returns to itself. Exhaustive over each block.
    for (depth, width) in GEOMS {
        for o in 0..(depth * width) {
            assert_eq!(
                ilv_orig(ilv_tx_pos(o, depth, width), depth, width),
                o,
                "roundtrip o={o} D={depth} W={width}"
            );
        }
    }
}

#[test]
fn the_interleaver_is_a_permutation_no_collisions_no_gaps() {
    // The transmit positions of the D*W originals are exactly {0..D*W}, each once -- so no datagram
    // is dropped or aliased onto another's slot.
    for (depth, width) in GEOMS {
        let n = depth * width;
        let mut hit = vec![false; n as usize];
        for o in 0..n {
            let t = ilv_tx_pos(o, depth, width);
            assert!(t < n, "tx pos in range: o={o} t={t}");
            assert!(!hit[t as usize], "two originals collide at tx pos {t}");
            hit[t as usize] = true;
        }
        assert!(
            hit.iter().all(|&h| h),
            "every transmit slot is filled (a bijection)"
        );
    }
}

#[test]
fn a_burst_of_adjacent_transmit_positions_lands_in_distinct_codewords() {
    // The whole point: a fading burst of B <= depth consecutive TRANSMITTED datagrams touches B
    // DISTINCT codewords -> at most one error per FEC group -> recoverable. Sweep every window.
    for (depth, width) in GEOMS {
        let n = depth * width;
        for start in 0..n {
            let burst = depth.min(n - start); // a burst up to `depth` long
            let mut seen = vec![false; (depth.max(width) * width) as usize + 1];
            for k in 0..burst {
                let t = start + k;
                let cw = ilv_codeword(ilv_orig(t, depth, width), width);
                assert!(
                    !seen[cw as usize],
                    "burst hit codeword {cw} twice (D={depth} W={width} start={start})"
                );
                seen[cw as usize] = true;
            }
        }
    }
}

#[test]
fn the_first_column_burst_maps_one_to_one_onto_codewords() {
    // Concrete pin from the spec: transmit positions 0..depth (the first column) are codewords
    // 0..depth in order, and position `depth` wraps to the next column back at codeword 0.
    let (depth, width) = (8u32, 4u32);
    for t in 0..depth {
        assert_eq!(
            ilv_codeword(ilv_orig(t, depth, width), width),
            t,
            "t{t} -> codeword {t}"
        );
    }
    assert_eq!(
        ilv_codeword(ilv_orig(depth, depth, width), width),
        0,
        "t=depth wraps to codeword 0"
    );
}

#[test]
fn the_adaptive_depth_matches_and_survives_the_measured_burst() {
    assert_eq!(choose_depth(0), 1, "no burst -> a valid depth of 1");
    assert_eq!(choose_depth(5), 5, "burst 5 -> depth 5");
    assert_eq!(choose_depth(12), 12, "burst 12 -> depth 12");
    assert_eq!(
        choose_depth(1000),
        DEPTH_CAP,
        "a huge burst clamps to the cap"
    );
    // A depth below the burst fails; the adaptive choice always survives (up to the cap).
    assert!(!depth_survives(8, 12), "fixed depth 8 fails a burst of 12");
    for burst in 0..DEPTH_CAP {
        assert!(
            depth_survives(choose_depth(burst), burst),
            "adaptive depth survives burst {burst}"
        );
    }
    // Past the cap, depth is clamped, so only bursts up to the cap are survivable -- pinned honestly.
    assert!(
        !depth_survives(choose_depth(DEPTH_CAP + 10), DEPTH_CAP + 10),
        "beyond the cap is not survivable (bounded latency)"
    );
}
