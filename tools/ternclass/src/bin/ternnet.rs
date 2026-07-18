// TRAINED ternary RF-net inference -- runs on the Zynq ARM PS.
// Reads raw int16 I,Q from stdin (iio_readdev stream), extracts the same 8
// features the net was trained on (real over-the-air captures), runs the
// 2-layer net whose every weight is in {-1,0,+1}, prints the class.
// Classes: noise | tone | dsssA | dsssB | wide.
include!("../weights.rs");
use std::io::{self, Read};
const FS: f32 = 30.72e6;
const F_IF: f32 = 3.0e6;
const SPC: usize = 16;
fn classify(buf: &[u8]) -> (usize, [f32; 8]) {
    let n = buf.len() / 4;
    let mut re = vec![0f32; n];
    let mut im = vec![0f32; n];
    for i in 0..n {
        re[i] = i16::from_le_bytes([buf[i*4], buf[i*4+1]]) as f32;
        im[i] = i16::from_le_bytes([buf[i*4+2], buf[i*4+3]]) as f32;
    }
    let (mr, mi) = (re.iter().sum::<f32>()/n as f32, im.iter().sum::<f32>()/n as f32);
    // derotate by the known +3 MHz system IF
    let w = 2.0*std::f32::consts::PI*F_IF/FS;
    let (mut dr, mut di) = (vec![0f32;n], vec![0f32;n]);
    for i in 0..n {
        let (c,s) = ((w*i as f32).cos(), (w*i as f32).sin());
        let (x,y) = (re[i]-mr, im[i]-mi);
        dr[i] = x*c + y*s;          // (x+iy)*e^{-iwt}
        di[i] = y*c - x*s;
    }
    let e: f32 = (0..n).map(|i| dr[i]*dr[i]+di[i]*di[i]).sum::<f32>()/n as f32 + 1e-9;
    let mut flips = 0usize;
    for i in 1..n { if dr[i]*dr[i-1] + di[i]*di[i-1] < 0.0 { flips += 1; } }
    let flip = flips as f32/(n-1) as f32;
    let ac = |k: usize| -> f32 {
        let (mut sr, mut si) = (0f32, 0f32);
        for i in k..n { sr += dr[i]*dr[i-k] + di[i]*di[i-k]; si += di[i]*dr[i-k] - dr[i]*di[i-k]; }
        (sr*sr+si*si).sqrt()/((n-k) as f32)/e
    };
    let lr = 63*SPC;                 // 1008-sample PN reference
    let nr = (lr as f32).sqrt();
    let pk = |pn: &[i8]| -> f32 {
        let mut refv = vec![0f32; lr];
        for c in 0..63 { for s in 0..SPC { refv[c*SPC+s] = pn[c] as f32; } }
        let mut best = 0f32;
        let mut o = 0usize;
        while o + lr < n {
            let (mut sr, mut si, mut en) = (0f32, 0f32, 0f32);
            for i in 0..lr {
                sr += dr[o+i]*refv[i]; si += di[o+i]*refv[i];
                en += dr[o+i]*dr[o+i] + di[o+i]*di[o+i];
            }
            let c = (sr*sr+si*si).sqrt()/(en.sqrt()*nr + 1e-9);
            if c > best { best = c; }
            o += 32;
        }
        best
    };
    let papr = (0..n).map(|i| dr[i]*dr[i]+di[i]*di[i]).fold(0f32,f32::max)/e;
    let x = [flip, ac(1), ac(8), ac(16), pk(&PNA), pk(&PNB),
             papr.min(20.0)/20.0, (e+1.0).log10()/5.0];
    // standardize + ternary forward (weights {-1,0,+1}, per-layer scale)
    let mut xs = [0f32; 8];
    for i in 0..8 { xs[i] = (x[i]-MU[i])/SD[i]; }
    let mut h = [0f32; 16];
    for j in 0..16 {
        let mut acc = 0f32;
        for i in 0..8 { let q = W1[j*8+i]; if q>0 {acc+=xs[i];} else if q<0 {acc-=xs[i];} }
        h[j] = (A1*acc + B1[j]).max(0.0);
    }
    let mut z = [0f32; 5];
    for k in 0..5 {
        let mut acc = 0f32;
        for j in 0..16 { let q = W2[k*16+j]; if q>0 {acc+=h[j];} else if q<0 {acc-=h[j];} }
        z[k] = A2*acc + B2[k];
    }
    let (mut bi, mut bv) = (0usize, z[0]);
    for k in 1..5 { if z[k] > bv { bv = z[k]; bi = k; } }
    (bi, x)
}

// Majority-of-3 voting: split the capture into 3 blocks, classify each,
// take the majority (ties -> the highest-vote earliest class). One marginal
// window can no longer flip the verdict.
fn main() {
    let mut buf = Vec::new();
    io::stdin().read_to_end(&mut buf).unwrap();
    let names = ["noise","tone","dsssA","dsssB","wide"];
    let n = buf.len() / 4;
    if n < 2048 { println!("class=?? (need samples)"); return; }
    let nb = if n >= 3*8192 { 3 } else { 1 };
    let blk = (n / nb) * 4;
    let mut votes = [0usize; 5];
    let mut lastf = [0f32; 8];
    for b in 0..nb {
        let (c, f) = classify(&buf[b*blk..(b+1)*blk]);
        votes[c] += 1; lastf = f;
    }
    let (mut bi, mut bv) = (0usize, votes[0]);
    for k in 1..5 { if votes[k] > bv { bv = votes[k]; bi = k; } }
    println!("votes[{} {} {} {} {}] feats[flip={:.3} pA={:.2} pB={:.2}] -> class={}",
             votes[0], votes[1], votes[2], votes[3], votes[4],
             lastf[0], lastf[4], lastf[5], names[bi]);
}
