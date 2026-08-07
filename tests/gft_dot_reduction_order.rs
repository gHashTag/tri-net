//! gft_dot_reduction_order -- GF-T addition is NON-ASSOCIATIVE (round-toward-zero renorm), so the
//! order in which a dot product folds its lane products is part of the answer, not an implementation
//! detail. The silicon MAC (fpga/gft/gft_dot4.v) reduces with a balanced tree -- (p0+p1)+(p2+p3) --
//! so any verifier that recomputes a dot to accept-or-slash a claim MUST fold in that same tree, or
//! it will compute a different value and slash an HONEST executor.
//!
//! This pins that requirement with a silicon-backed witness. For the lane-product vector
//!   p = [(40,64), (45,0), (46,256), (40,64)]
//! iverilog on gft_add.v gives:
//!   TREE (p0+p1)+(p2+p3) = (47,9)      <- what gft_dot4.v produces (its 3-adder tree)
//!   SEQ  ((p0+p1)+p2)+p3 = (47,8)      <- a left-fold; one ULP low
//! The two differ, so reduction order is load-bearing. A verifier folding sequentially would reject
//! the honest (47,9) silicon result. (This is exactly why gft_dot_verifiable's left-fold oracle is
//! only sound at <=2 lanes, where tree==seq -- see the note corrected in that file.)

// ---- GF-T16 add, transcribed from fpga/gft/gft_add.v (mant_one 512, mant_bits 9, sig 10). ----
const MANT_ONE: u64 = 512;
const OMAX: u64 = 80;
const SIG: u64 = 10;

fn add(a: (u64, u64), b: (u64, u64)) -> (u64, u64) {
    let (hi, lo) = if a.0 > b.0 || (a.0 == b.0 && a.1 >= b.1) {
        (a, b)
    } else {
        (b, a)
    };
    let d = hi.0 - lo.0;
    let sb = if d >= SIG { 0 } else { (MANT_ONE + lo.1) >> d };
    let sum = (MANT_ONE + hi.1) + sb;
    let carry = sum >= 2 * MANT_ONE;
    let off = if carry {
        let e = hi.0 + 1;
        if e >= OMAX {
            OMAX
        } else {
            e
        }
    } else {
        hi.0
    };
    let mant = if carry {
        (sum >> 1) - MANT_ONE
    } else {
        sum - MANT_ONE
    };
    (off, mant)
}

/// The silicon canonical 4-lane reduction: the balanced tree of gft_dot4.v (a01, a23, atop).
fn tree4(p: [(u64, u64); 4]) -> (u64, u64) {
    let s01 = add(p[0], p[1]);
    let s23 = add(p[2], p[3]);
    add(s01, s23)
}

/// A left-fold reduction -- NOT what the silicon does; here to witness the divergence.
fn seq4(p: [(u64, u64); 4]) -> (u64, u64) {
    add(add(add(p[0], p[1]), p[2]), p[3])
}

// The divergent lane-product vector, and the iverilog-confirmed results for each order.
const P: [(u64, u64); 4] = [(40, 64), (45, 0), (46, 256), (40, 64)];
const TREE_RESULT: (u64, u64) = (47, 9); // gft_dot4.v tree, confirmed on iverilog
const SEQ_RESULT: (u64, u64) = (47, 8); // left-fold, confirmed on iverilog

#[test]
fn the_silicon_tree_order_is_the_canonical_dot_result() {
    assert_eq!(
        tree4(P),
        TREE_RESULT,
        "the gft_dot4.v balanced tree gives (47,9)"
    );
}

#[test]
fn a_reordered_reduction_diverges_by_one_ulp() {
    // Non-associativity is real: left-fold gives (47,8), the silicon tree gives (47,9).
    assert_eq!(seq4(P), SEQ_RESULT, "left-fold gives (47,8)");
    assert_ne!(
        seq4(P),
        tree4(P),
        "reduction order is load-bearing: a reordered fold is a DIFFERENT value"
    );
}

#[test]
fn a_verifier_folding_sequentially_would_falsely_slash_the_honest_result() {
    // An executor runs the silicon tree and returns TREE_RESULT (honest). A verifier that recomputes
    // with the wrong (sequential) order compares against SEQ_RESULT and rejects -- a false slash.
    let honest_executor_result = tree4(P);
    let verifier_tree = tree4(P); // correct: same order as silicon -> accept
    let verifier_seq = seq4(P); // wrong order -> would reject the honest result
    assert_eq!(
        verifier_tree, honest_executor_result,
        "tree-order verifier accepts the honest result"
    );
    assert_ne!(
        verifier_seq, honest_executor_result,
        "seq-order verifier would falsely slash it"
    );
}

#[test]
fn at_two_lanes_the_single_add_is_order_free() {
    // A 2-lane dot is one add, and gft_add orders its operands by magnitude internally, so it is
    // commutative: add(a,b) == add(b,a). That single-op safety is exactly why the existing 2-lane
    // gft_dot_verifiable tests never surfaced the divergence -- it needs >=3 adds (>=4 lanes).
    for a in [(40u64, 64u64), (45, 0), (46, 256)] {
        for b in [(40u64, 0u64), (45, 256), (47, 128)] {
            assert_eq!(
                add(a, b),
                add(b, a),
                "2-lane add is commutative -> order-free"
            );
        }
    }
}
