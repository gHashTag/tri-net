// Ternary RF classifier -- runs on the Zynq ARM PS. Reads raw int16 I,Q from
// stdin (the iio_readdev byte stream), extracts 2 features, runs a 2-layer net
// whose every weight is in {-1,0,+1} (each MAC a +x/-x/0 sign-select -- the same
// primitive as the FPGA despreader and the BitNet layer), prints the class.
use std::io::{self, Read};
fn sel(w: i32, x: i32) -> i32 { if w > 0 { x } else if w < 0 { -x } else { 0 } }
fn main() {
    let mut buf = Vec::new();
    io::stdin().read_to_end(&mut buf).unwrap();
    let n = buf.len() / 4; // 2 x i16 per complex sample
    if n < 2 { println!("class=?? (no samples)"); return; }
    let s = |i: usize| -> (i64, i64) {
        let lo = |o: usize| i16::from_le_bytes([buf[o], buf[o + 1]]) as i64;
        (lo(i * 4), lo(i * 4 + 2))
    };
    let (mut sa, mut cneg) = (0i64, 0i64);
    let (mut pi, mut pq) = s(0);
    for i in 0..n {
        let (ii, qq) = s(i);
        sa += ii.abs() + qq.abs();
        if i > 0 && ii * pi + qq * pq < 0 { cneg += 1; } // Re(s[n] conj s[n-1]) < 0 -> chip flip
        pi = ii; pq = qq;
    }
    let energy = sa as f64 / n as f64;
    let fneg = cneg as f64 / (n - 1) as f64;
    // The phase-flip rate alone separates the three classes and is INVARIANT to
    // signal level (so a drifting noise floor no longer confuses it):
    //   noise ~0.5-0.7 (random) | tone ~0.000 (smooth) | spread ~0.03 (chip edges).
    let fhi = if fneg > 0.15 { 4 } else { -4 }; // many flips  -> noise
    let flo = if fneg < 0.005 { 4 } else { -4 }; // ~no flips   -> tone
    let hn = sel(1, fhi);                       // noise:  many flips
    let ht = sel(1, flo);                       // tone:   no flips
    let hs = sel(-1, fhi) + sel(-1, flo);       // spread: some but not many
    let (mut best, mut cls) = (hn, "noise");
    if ht > best { best = ht; cls = "tone"; }
    if hs > best { cls = "spread"; }
    println!("energy={:.1} flips={:.3} scores[noise={} tone={} spread={}] -> class={}",
             energy, fneg, hn, ht, hs, cls);
}
