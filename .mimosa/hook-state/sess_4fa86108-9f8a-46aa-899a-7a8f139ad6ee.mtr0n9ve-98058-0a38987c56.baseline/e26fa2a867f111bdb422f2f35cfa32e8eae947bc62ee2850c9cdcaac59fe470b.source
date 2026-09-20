// Tiny ternary char-level code LM -- GENERATES on the Zynq ARM PS.
// Causal self-attention + FFN, every projection weight in {-1,0,+1}; greedy
// decode. argv[1] = seed text, argv[2] = chars to generate. This is the
// IGLA-Coder shape (a ternary code transformer) running on the radio node.
include!("../lm_w.rs");
use std::env;
fn mt(x:&[f32],w:&[i8],a:f32,r:usize,k:usize,c:usize)->Vec<f32>{
    let mut o=vec![0f32;r*c];
    for i in 0..r{for j in 0..c{let mut s=0f32;
        for t in 0..k{let q=w[t*c+j];if q>0{s+=x[i*k+t];}else if q<0{s-=x[i*k+t];}}
        o[i*c+j]=s*a;}}o
}
fn step(ctx:&[usize])->usize{
    let s=ctx.len().max(L)-L; let toks=&ctx[s..];      // last L tokens
    let sl=toks.len();
    let mut h=vec![0f32;sl*D];
    for p in 0..sl{for d in 0..D{h[p*D+d]=EMB[toks[p]*D+d]+POS[p*D+d];}}
    let q=mt(&h,&WQ,WQ_A,sl,D,D);let k=mt(&h,&WK,WK_A,sl,D,D);let v=mt(&h,&WV,WV_A,sl,D,D);
    let sc=(D as f32).sqrt(); let mut att=vec![0f32;sl*D];
    for i in 0..sl{
        let mut e=vec![0f32;sl];let mut mx=f32::MIN;
        for j in 0..=i{let mut s=0f32;for d in 0..D{s+=q[i*D+d]*k[j*D+d];}e[j]=s/sc;if e[j]>mx{mx=e[j];}}
        let mut sm=0f32;for j in 0..=i{e[j]=(e[j]-mx).exp();sm+=e[j];}
        for d in 0..D{let mut s=0f32;for j in 0..=i{s+=e[j]/sm*v[j*D+d];}att[i*D+d]=s;}
    }
    let ao=mt(&att,&WO,WO_A,sl,D,D);
    let mut h1=vec![0f32;sl*D];for i in 0..sl*D{h1[i]=h[i]+ao[i];}
    let f1=mt(&h1,&W1,W1_A,sl,D,DFF); let mut r=vec![0f32;sl*DFF];for i in 0..sl*DFF{r[i]=f1[i].max(0.0);}
    let f2=mt(&r,&W2,W2_A,sl,DFF,D); let mut h2=vec![0f32;sl*D];for i in 0..sl*D{h2[i]=h1[i]+f2[i];}
    let last=&h2[(sl-1)*D..sl*D];
    let lo=mt(last,&WC,WC_A,1,D,V);
    let mut bi=0;let mut bv=lo[0]+BC[0];
    for c in 1..V{let z=lo[c]+BC[c];if z>bv{bv=z;bi=c;}} bi
}
fn main(){
    let a:Vec<String>=env::args().collect();
    let seed=a.get(1).cloned().unwrap_or("fn main(".into());
    let n:usize=a.get(2).and_then(|s|s.parse().ok()).unwrap_or(40);
    let cv:Vec<char>=CHARS.chars().collect();
    let mut ctx:Vec<usize>=seed.chars().map(|c|cv.iter().position(|&x|x==c).unwrap_or(0)).collect();
    for _ in 0..n{let nx=step(&ctx);ctx.push(nx);}
    let out:String=ctx.iter().map(|&i|cv[i]).collect();
    println!("{}",out);
}
