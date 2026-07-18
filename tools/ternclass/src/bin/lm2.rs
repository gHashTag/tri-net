// 2-layer TERNARY code LM with temperature sampling -- runs on the Zynq ARM PS.
// NL stacked blocks (causal attention + FFN), every projection weight {-1,0,+1}.
include!("../lm2_w.rs");
use std::env;
fn mt(x:&[f32],w:&[i8],a:f32,r:usize,k:usize,c:usize)->Vec<f32>{
    let mut o=vec![0f32;r*c];
    for i in 0..r{for j in 0..c{let mut s=0f32;
        for t in 0..k{let q=w[t*c+j];if q>0{s+=x[i*k+t];}else if q<0{s-=x[i*k+t];}}
        o[i*c+j]=s*a;}}o
}
fn wq(l:usize)->(&'static [i8],f32){[( &WQ0[..],WQ0_A),(&WQ1[..],WQ1_A)][l]}
fn wk(l:usize)->(&'static [i8],f32){[(&WK0[..],WK0_A),(&WK1[..],WK1_A)][l]}
fn wv(l:usize)->(&'static [i8],f32){[(&WV0[..],WV0_A),(&WV1[..],WV1_A)][l]}
fn wo(l:usize)->(&'static [i8],f32){[(&WO0[..],WO0_A),(&WO1[..],WO1_A)][l]}
fn w1(l:usize)->(&'static [i8],f32){[(&W10[..],W10_A),(&W11[..],W11_A)][l]}
fn w2(l:usize)->(&'static [i8],f32){[(&W20[..],W20_A),(&W21[..],W21_A)][l]}
fn logits(ctx:&[usize])->Vec<f32>{
    let s=ctx.len().max(L)-L; let t=&ctx[s..]; let sl=t.len();
    let mut h=vec![0f32;sl*D];
    for p in 0..sl{for d in 0..D{h[p*D+d]=EMB[t[p]*D+d]+POS[p*D+d];}}
    for l in 0..NL{
        let (a,aa)=wq(l);let q=mt(&h,a,aa,sl,D,D);
        let (a,aa)=wk(l);let k=mt(&h,a,aa,sl,D,D);
        let (a,aa)=wv(l);let v=mt(&h,a,aa,sl,D,D);
        let sc=(D as f32).sqrt(); let mut att=vec![0f32;sl*D];
        for i in 0..sl{
            let mut e=vec![0f32;sl];let mut mx=f32::MIN;
            for j in 0..=i{let mut s=0f32;for d in 0..D{s+=q[i*D+d]*k[j*D+d];}e[j]=s/sc;if e[j]>mx{mx=e[j];}}
            let mut sm=0f32;for j in 0..=i{e[j]=(e[j]-mx).exp();sm+=e[j];}
            for d in 0..D{let mut s=0f32;for j in 0..=i{s+=e[j]/sm*v[j*D+d];}att[i*D+d]=s;}
        }
        let (a,aa)=wo(l);let ao=mt(&att,a,aa,sl,D,D);
        let mut h1=vec![0f32;sl*D];for i in 0..sl*D{h1[i]=h[i]+ao[i];}
        let (a,aa)=w1(l);let f1=mt(&h1,a,aa,sl,D,DFF);let mut r=vec![0f32;sl*DFF];for i in 0..sl*DFF{r[i]=f1[i].max(0.0);}
        let (a,aa)=w2(l);let f2=mt(&r,a,aa,sl,DFF,D);
        for i in 0..sl*D{h[i]=h1[i]+f2[i];}
    }
    let last=&h[(sl-1)*D..sl*D];
    let mut lo=mt(last,&WC,WC_A,1,D,V);
    for c in 0..V{lo[c]+=BC[c];} lo
}
fn main(){
    let a:Vec<String>=env::args().collect();
    let seed=a.get(1).cloned().unwrap_or("fn ".into());
    let n:usize=a.get(2).and_then(|s|s.parse().ok()).unwrap_or(60);
    let temp:f32=a.get(3).and_then(|s|s.parse().ok()).unwrap_or(0.6);
    let sd:u64=a.get(4).and_then(|s|s.parse().ok()).unwrap_or(12345);
    let cv:Vec<char>=CHARS.chars().collect();
    let mut ctx:Vec<usize>=seed.chars().map(|c|cv.iter().position(|&x|x==c).unwrap_or(0)).collect();
    let mut rng=sd;
    let mut rand=||{rng^=rng<<13;rng^=rng>>7;rng^=rng<<17;(rng>>11) as f32/(1u64<<53) as f32};
    for _ in 0..n{
        let lo=logits(&ctx);
        if temp<=0.0 { let mut bi=0;let mut bv=lo[0];for c in 1..V{if lo[c]>bv{bv=lo[c];bi=c;}} ctx.push(bi); }
        else {
            let mx=lo.iter().cloned().fold(f32::MIN,f32::max);
            let mut p:Vec<f32>=lo.iter().map(|z|((z-mx)/temp).exp()).collect();
            let s:f32=p.iter().sum(); for x in p.iter_mut(){*x/=s;}
            let r=rand(); let mut acc=0f32; let mut pick=V-1;
            for c in 0..V{acc+=p[c]; if r<=acc {pick=c;break;}}
            ctx.push(pick);
        }
    }
    let out:String=ctx.iter().map(|&i|cv[i]).collect();
    println!("{}",out);
}
