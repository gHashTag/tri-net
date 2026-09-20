// Tiny TERNARY TRANSFORMER forward -- runs on the Zynq ARM PS.
// 1 self-attention head (softmax) + FFN, every projection weight in {-1,0,+1}.
// Reads L token ids from argv, prints the predicted class. This is the same
// architecture as IGLA-Coder (attention + FFN, ternary weights), in miniature,
// executing on the radio node's own silicon.
include!("../xfmr_w.rs");
use std::env;
fn mt(x:&[f32], w:&[i8], a:f32, r:usize, k:usize, cc:usize)->Vec<f32>{ // x[r,k] * (w[k,cc]*a)
    let mut o=vec![0f32;r*cc];
    for i in 0..r { for j in 0..cc { let mut s=0f32;
        for t in 0..k { let q=w[t*cc+j]; if q>0 {s+=x[i*k+t];} else if q<0 {s-=x[i*k+t];} }
        o[i*cc+j]=s*a; } }
    o
}
fn main(){
    let toks:Vec<usize>=env::args().skip(1).map(|s|s.parse().unwrap()).collect();
    let mut h=vec![0f32;L*D];
    for p in 0..L { for d in 0..D { h[p*D+d]=EMB[toks[p]*D+d]+POS[p*D+d]; } }
    let q=mt(&h,&WQ,WQ_A,L,D,D); let k=mt(&h,&WK,WK_A,L,D,D); let v=mt(&h,&WV,WV_A,L,D,D);
    let sc=(D as f32).sqrt();
    let mut att=vec![0f32;L*D];
    for i in 0..L {
        let mut e=vec![0f32;L]; let mut mx=f32::MIN;
        for j in 0..L { let mut s=0f32; for d in 0..D {s+=q[i*D+d]*k[j*D+d];} e[j]=s/sc; if e[j]>mx{mx=e[j];} }
        let mut sm=0f32; for j in 0..L { e[j]=(e[j]-mx).exp(); sm+=e[j]; }
        for d in 0..D { let mut s=0f32; for j in 0..L { s+=e[j]/sm*v[j*D+d]; } att[i*D+d]=s; }
    }
    let ao=mt(&att,&WO,WO_A,L,D,D);
    let mut h1=vec![0f32;L*D]; for i in 0..L*D { h1[i]=h[i]+ao[i]; }
    let ff1=mt(&h1,&W1,W1_A,L,D,DFF);
    let mut r=vec![0f32;L*DFF]; for i in 0..L*DFF { r[i]=ff1[i].max(0.0); }
    let ff2=mt(&r,&W2,W2_A,L,DFF,D);
    let mut h2=vec![0f32;L*D]; for i in 0..L*D { h2[i]=h1[i]+ff2[i]; }
    let pooled=&h2[0..D];
    let logit=mt(pooled,&WC,WC_A,1,D,C);
    let mut bi=0; let mut bv=logit[0]+BC[0];
    for c in 1..C { let z=logit[c]+BC[c]; if z>bv {bv=z; bi=c;} }
    println!("{}", bi);
}
