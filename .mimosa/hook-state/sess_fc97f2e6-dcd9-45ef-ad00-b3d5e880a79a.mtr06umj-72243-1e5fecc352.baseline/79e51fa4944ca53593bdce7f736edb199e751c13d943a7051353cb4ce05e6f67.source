//! ladder_canon_ssot -- CI guard for the GF-T ladder's SINGLE SOURCE OF TRUTH (specs/
//! tri_gft_ladder.t27). Every downstream layer derives its rung geometry from here: the silicon
//! bias (gft_mul32 uses 364), the validity special-row (gfvalid_finiteness), and the settle
//! offset_max all trust that width -> Et -> (bias, mantissa, offset_max) is ONE consistent table.
//! The ratified golden rule is Et(k) = fib(k+1)+1, mant(k) = fib(k+1)^2 -- NOT Et = log2(width),
//! which coincides only through GF-T16 and once gave GF-T32 -> Et5 (bias 242) while the hardware
//! used Et6 (bias 364). fib/width_to_et are only loosely referenced; the self-consistency of the
//! WHOLE table -- and the log2 regression -- had no dedicated guard. This transcribes the canon and
//! pins that the constants, width_to_et, bias, and offset_max all derive from the one golden rule.

fn fib(n: u32) -> u32 {
    match n {
        0 => 0,
        1 => 1,
        2 => 1,
        3 => 2,
        4 => 3,
        5 => 5,
        6 => 8,
        7 => 13,
        8 => 21,
        9 => 34,
        10 => 55,
        _ => 0,
    }
}
fn gft_et_of_rung(k: u32) -> u32 {
    fib(k + 1) + 1
}
fn gft_mant_of_rung(k: u32) -> u32 {
    fib(k + 1) * fib(k + 1)
}
fn width_to_et(width: u32) -> u32 {
    // the constant table the spec exposes (GFT{w}_ET).
    match width {
        4 => 2,
        8 => 3,
        16 => 4,
        32 => 6,
        64 => 9,
        128 => 14,
        256 => 22,
        512 => 35,
        1024 => 56,
        _ => 0,
    }
}
fn gft_mant_bits(et: u32) -> u32 {
    // the constant table GFT{w}_MANT, keyed by Et.
    match et {
        2 => 1,
        3 => 4,
        4 => 9,
        6 => 25,
        9 => 64,
        14 => 169,
        22 => 441,
        35 => 1156,
        56 => 3025,
        _ => 0,
    }
}
fn gft_pow3_u64(et: u32) -> u64 {
    match et {
        2 => 9,
        3 => 27,
        4 => 81,
        6 => 729,
        9 => 19683,
        14 => 4_782_969,
        22 => 31_381_059_609,
        35 => 50_031_545_098_999_707,
        _ => 0, // Et56 (GF-T1024) overflows u64
    }
}
fn gft_bias_u64(et: u32) -> u64 {
    (gft_pow3_u64(et) - 1) / 2
}
fn gft_offset_max_u64(et: u32) -> u64 {
    gft_pow3_u64(et) - 1
}

// The ratified ladder: (width, rung index k). Et and mantissa follow from the golden rule.
const LADDER: [(u32, u32); 9] = [
    (4, 1),
    (8, 2),
    (16, 3),
    (32, 4),
    (64, 5),
    (128, 6),
    (256, 7),
    (512, 8),
    (1024, 9),
];

#[test]
fn width_to_et_matches_the_golden_fibonacci_rule_on_every_rung() {
    for (width, k) in LADDER {
        assert_eq!(
            width_to_et(width),
            gft_et_of_rung(k),
            "GF-T{width}: width_to_et must equal fib(k+1)+1"
        );
        assert_eq!(gft_et_of_rung(k), fib(k + 1) + 1, "the rule itself");
    }
    // The exact ratified Ets, spelled out.
    let ets: Vec<u32> = LADDER.iter().map(|&(w, _)| width_to_et(w)).collect();
    assert_eq!(
        ets,
        vec![2, 3, 4, 6, 9, 14, 22, 35, 56],
        "the canonical Et ladder"
    );
}

#[test]
fn the_gf_t32_log2_regression_stays_fixed() {
    // The historic bug: Et = log2(32) = 5 (bias (3^5-1)/2 = 121) instead of the golden fib(5)+1 = 6
    // (bias (3^6-1)/2 = 364, what the silicon gft_mul32 actually uses). Pin the golden value.
    assert_eq!(width_to_et(32), 6, "GF-T32 is Et6 (golden), not Et5 (log2)");
    assert_ne!(width_to_et(32), 5, "Et5 was the log2 bug");
    assert_eq!(
        gft_bias_u64(6),
        364,
        "GF-T32 bias = (3^6-1)/2 = 364, matching silicon gft_mul32"
    );
    assert_ne!(
        gft_bias_u64(6),
        121,
        "121 = (3^5-1)/2 would be the log2-Et5 bias"
    );
    // Below GF-T16, log2 and the golden rule coincide (that is why the bug hid there).
    assert_eq!(width_to_et(4), 2);
    assert_eq!(width_to_et(8), 3);
    assert_eq!(width_to_et(16), 4);
}

#[test]
fn the_mantissa_width_follows_fib_squared_and_matches_the_constant_table() {
    for (width, k) in LADDER {
        let et = width_to_et(width);
        assert_eq!(
            gft_mant_of_rung(k),
            fib(k + 1) * fib(k + 1),
            "mant(k) = fib(k+1)^2"
        );
        assert_eq!(
            gft_mant_bits(et),
            gft_mant_of_rung(k),
            "the GFT{width}_MANT constant == the golden mant(k)"
        );
    }
    let mants: Vec<u32> = LADDER
        .iter()
        .map(|&(w, _)| gft_mant_bits(width_to_et(w)))
        .collect();
    assert_eq!(
        mants,
        vec![1, 4, 9, 25, 64, 169, 441, 1156, 3025],
        "the canonical mantissa ladder (fib^2)"
    );
}

#[test]
fn bias_and_offset_max_derive_from_the_rung_and_are_monotone() {
    let mut prev_et = 0u32;
    let mut prev_omax = 0u64;
    for (width, _k) in LADDER {
        let et = width_to_et(width);
        // bias = (3^Et - 1)/2, offset_max = 3^Et - 1 (u64 for the upper rungs; Et56 overflows -> 0).
        if gft_pow3_u64(et) != 0 {
            assert_eq!(
                gft_bias_u64(et) * 2 + 1,
                gft_pow3_u64(et),
                "bias = (3^Et-1)/2 exactly"
            );
            assert_eq!(
                gft_offset_max_u64(et),
                gft_pow3_u64(et) - 1,
                "offset_max = 3^Et-1"
            );
            assert!(
                gft_offset_max_u64(et) > prev_omax,
                "offset_max strictly grows up the ladder"
            );
            prev_omax = gft_offset_max_u64(et);
        }
        assert!(et > prev_et, "Et strictly increases up the ladder");
        prev_et = et;
    }
    // Concrete money-rung values.
    assert_eq!(gft_offset_max_u64(9), 19682, "GF-T64 offset_max = 3^9-1");
    assert_eq!(gft_bias_u64(9), 9841, "GF-T64 bias = (3^9-1)/2");
}

#[test]
fn the_u64_upper_rungs_are_exact_and_gf_t1024_honestly_overflows() {
    assert_eq!(
        gft_pow3_u64(22),
        31_381_059_609,
        "3^22 (GF-T256) exceeds u32, exact in u64"
    );
    assert_eq!(
        gft_pow3_u64(35),
        50_031_545_098_999_707,
        "3^35 (GF-T512) is the largest that fits u64"
    );
    // GF-T1024 (Et56): 3^56 ~ 5.2e26 overflows u64, so the table returns 0 -- an honest ceiling, not
    // a silent wrap. A caller must use a bignum path for GF-T1024's offset_max.
    assert_eq!(
        gft_pow3_u64(56),
        0,
        "GF-T1024 (Et56) overflows u64 -> 0 (honest limit, not a wrap)"
    );
    assert_eq!(
        width_to_et(1024),
        56,
        "GF-T1024 is Et56 in the geometry table even though 3^56 needs a bignum"
    );
}
