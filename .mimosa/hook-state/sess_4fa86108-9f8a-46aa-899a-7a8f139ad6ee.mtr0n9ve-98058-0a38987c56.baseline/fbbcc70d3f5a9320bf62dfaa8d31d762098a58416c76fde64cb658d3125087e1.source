//! gft_dot_oracle -- an independent, cargo-testable oracle for the on-silicon streaming GF-T16
//! dot product. `fpga/gft/gft_macc_ax7203` computes a variable-length dot product on real hardware
//! (verified 4/4 over UART); this reproduces the exact encoded-domain arithmetic in integer Rust
//! and asserts the SAME packed results the FPGA returned -- closing the loop spec -> silicon -> oracle.
//!
//! gft_mul is transcribed from tri_gft_arith.t27 (also in gft_compute_challenge.rs); gft_add is
//! transcribed from fpga/gft/gft_add.v (SAME .t27 family: tri_gft_add). A streaming dot product
//! folds each product into the accumulator, exactly like gft_macc.
//!
//! Packed GF-T16 magnitude = (offset << 9) | mant; value = (1 + mant/512) * 2^(offset - 40).

const BIAS: u64 = 40;
const OFFSET_MAX: u64 = 80;
const MANT_ONE: u64 = 512;
const SIG_BITS: u32 = 10;

fn unpack(v: u16) -> (u64, u64) {
    ((v >> 9) as u64, (v & 0x1FF) as u64)
}
fn pack(off: u64, mant: u64) -> u16 {
    (((off & 0x7F) << 9) | (mant & 0x1FF)) as u16
}
fn decode(off: u64, mant: u64) -> f64 {
    (1.0 + mant as f64 / 512.0) * 2f64.powi(off as i32 - 40)
}

/// gft_mul in the encoded domain (integer; matches the spec + the silicon multiplier).
fn mul(a: u16, b: u16) -> (u64, u64) {
    let (oa, ma) = unpack(a);
    let (ob, mb) = unpack(b);
    let prod = (MANT_ONE + ma) * (MANT_ONE + mb);
    let carry = if prod >= (2 * MANT_ONE) * MANT_ONE {
        1
    } else {
        0
    };
    let mant = if carry == 1 {
        (prod / (2 * MANT_ONE)) - MANT_ONE
    } else {
        (prod / MANT_ONE) - MANT_ONE
    };
    let sum = oa + ob + carry;
    let off = if sum < BIAS {
        0
    } else {
        let r = sum - BIAS;
        if r >= OFFSET_MAX {
            OFFSET_MAX
        } else {
            r
        }
    };
    (off, mant)
}

/// gft_add (same-sign) in the encoded domain (integer; matches fpga/gft/gft_add.v + tri_gft_add).
fn add(a: (u64, u64), b: (u64, u64)) -> (u64, u64) {
    let (a_off, a_m) = a;
    let (b_off, b_m) = b;
    let (hi_off, hi_m, lo_off, lo_m) = if a_off >= b_off {
        (a_off, a_m, b_off, b_m)
    } else {
        (b_off, b_m, a_off, a_m)
    };
    let d = hi_off - lo_off;
    let sb = if d >= SIG_BITS as u64 {
        0
    } else {
        (MANT_ONE + lo_m) >> d
    };
    let sum = (MANT_ONE + hi_m) + sb;
    let carry = sum >= 2 * MANT_ONE;
    let off = if carry {
        let e = hi_off + 1;
        if e >= OFFSET_MAX {
            OFFSET_MAX
        } else {
            e
        }
    } else {
        hi_off
    };
    let mant = if carry {
        (sum >> 1) - MANT_ONE
    } else {
        sum - MANT_ONE
    };
    (off, mant)
}

/// Streaming dot product over packed (a,b) pairs -- the software twin of gft_macc.
fn dot(pairs: &[(u16, u16)]) -> u16 {
    let mut acc = (0u64, 0u64);
    for (i, &(a, b)) in pairs.iter().enumerate() {
        let p = mul(a, b);
        acc = if i == 0 { p } else { add(acc, p) };
    }
    pack(acc.0, acc.1)
}

#[test]
fn oracle_matches_silicon() {
    // The EXACT vectors verified bit-exact on the AX7203 over UART (docs/VERIFIABLE_COMPUTE.md).
    assert_eq!(
        dot(&[(0x5200, 0x5200); 4]),
        0x5800,
        "len-4: 4x (41,0)^2 = 16"
    );
    assert_eq!(
        dot(&[(0x5300, 0x5300), (0x5800, 0x5A00)]),
        0x6209,
        "len-2: 9 + 512 = 521"
    );
    assert_eq!(dot(&[(0x6400, 0x6400)]), 0x7800, "len-1: (50,0)^2 = 2^20");
    assert_eq!(
        dot(&[(0x5300, 0x5300), (0x5200, 0x5200), (0x5400, 0x5200)]),
        0x58A0,
        "len-3: 9+4+8 = 21"
    );
}

#[test]
fn oracle_matches_the_value_domain() {
    // Each packed result decodes to the real sum (within GF-T16's representable precision).
    let cases: &[(&[(u16, u16)], f64)] = &[
        (&[(0x5200, 0x5200); 4], 16.0),
        (&[(0x5300, 0x5300), (0x5800, 0x5A00)], 521.0),
        (&[(0x6400, 0x6400)], 1048576.0),
        (
            &[(0x5300, 0x5300), (0x5200, 0x5200), (0x5400, 0x5200)],
            21.0,
        ),
    ];
    for (pairs, want) in cases {
        let (off, mant) = unpack(dot(pairs));
        let got = decode(off, mant);
        assert!((got - want).abs() / want < 0.004, "decoded {got} vs {want}");
    }
}
