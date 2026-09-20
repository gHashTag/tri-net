//! gft_upper_rung_precision -- the ladder's precision GUARANTEE keeps improving to the TOP,
//! where f64 cannot reach. gft_ladder_accuracy proved ACTUAL dot-product error decreases through
//! GF-T32 in f64; but GF-T64..1024 have 64..3025-bit mantissas, far past f64's 52. The per-value
//! quantization quantum of a rung is 2^-mant_bits, so the ladder's precision bound shrinks iff
//! mant_bits grows. Using the ratified Fibonacci rule mant_bits(k) = fib(k+1)^2, this proves in
//! exact BigUint that the quantum strictly shrinks all the way to GF-T1024 (mant_bits 3025).

use num_bigint::BigUint;

fn fib(n: u32) -> u64 {
    let (mut a, mut b) = (0u64, 1u64);
    for _ in 0..n {
        let t = a + b;
        a = b;
        b = t;
    }
    a
}

/// Ratified rung mantissa width: mant(k) = fib(k+1)^2 (GF-T4 = k1 .. GF-T1024 = k9).
fn mant_bits(k: u32) -> u32 {
    let f = fib(k + 1);
    (f * f) as u32
}

/// The quantization quantum's inverse for a rung: 2^mant_bits (BigUint -- mant_bits reaches 3025).
fn inv_quantum(k: u32) -> BigUint {
    BigUint::from(1u32) << mant_bits(k) as usize
}

const RUNGS: [(&str, u32, u32); 9] = [
    ("GF-T4", 1, 1),
    ("GF-T8", 2, 4),
    ("GF-T16", 3, 9),
    ("GF-T32", 4, 25),
    ("GF-T64", 5, 64),
    ("GF-T128", 6, 169),
    ("GF-T256", 7, 441),
    ("GF-T512", 8, 1156),
    ("GF-T1024", 9, 3025),
];

#[test]
fn mant_bits_follow_the_ratified_fibonacci_rule() {
    for &(name, k, expected) in RUNGS.iter() {
        assert_eq!(
            mant_bits(k),
            expected,
            "{name}: mant_bits = fib(k+1)^2 = {expected}"
        );
    }
}

#[test]
fn the_precision_quantum_strictly_shrinks_to_the_top_of_the_ladder() {
    // 2^mant_bits strictly increases up the ladder -> the quantum 2^-mant_bits strictly shrinks,
    // so a higher rung is always at least as precise, right up to GF-T1024 (beyond f64's reach).
    for w in RUNGS.windows(2) {
        let lo = inv_quantum(w[0].1);
        let hi = inv_quantum(w[1].1);
        assert!(hi > lo, "{} quantum is finer than {}", w[1].0, w[0].0);
    }
    // The reach past f64: GF-T1024's quantum is 2^(3025-25) = 2^3000 times finer than GF-T32's --
    // a ratio no f64 could hold, but exact in BigUint.
    let ratio = inv_quantum(9) / inv_quantum(4); // 2^(3025 - 25)
    assert_eq!(
        ratio,
        BigUint::from(1u32) << 3000usize,
        "GF-T1024 is 2^3000x finer than GF-T32"
    );
    // And the top quantum's denominator has ~910 decimal digits -- concrete evidence f64 can't reach.
    assert!(
        inv_quantum(9).to_string().len() > 900,
        "2^3025 has >900 decimal digits"
    );
}
