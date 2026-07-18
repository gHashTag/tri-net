// CSMA gate driven by the trained ternary net. Reads a capture on stdin,
// runs the same 5-class network-sensing model, and prints a transmit DECISION:
// class=noise -> "CLEAR: transmit" ; anything else -> "BUSY (<class>): defer".
// This is the classifier closed into an actual network-card action.
include!("../weights.rs");
use std::io::{self, Read};
const FS: f32 = 30.72e6; const F_IF: f32 = 3.0e6; const SPC: usize = 16;
fn classify(buf: &[u8]) -> usize {
    let n = buf.len()/4; if n < 2048 { return 0; }
    let mut re=vec![0f32;n]; let mut im=vec![0f32;n];
    for i in 0..n { re[i]=i16::from_le_bytes([buf[i*4],buf[i*4+1]]) as f32; im[i]=i16::from_le_bytes([buf[i*4+2],buf[i*4+3]]) as f32; }
    let (mr,mi)=(re.iter().sum::<f32>()/n as f32, im.iter().sum::<f32>()/n as f32);
    let w=2.0*std::f32::consts::PI*F_IF/FS; let (mut dr,mut di)=(vec![0f32;n],vec![0f32;n]);
    for i in 0..n { let (c,s)=((w*i as f32).cos(),(w*i as f32).sin()); let (x,y)=(re[i]-mr,im[i]-mi); dr[i]=x*c+y*s; di[i]=y*c-x*s; }
    let e:f32=(0..n).map(|i|dr[i]*dr[i]+di[i]*di[i]).sum::<f32>()/n as f32+1e-9;
    let mut fl=0usize; for i in 1..n { if dr[i]*dr[i-1]+di[i]*di[i-1]<0.0 {fl+=1;} }
    let flip=fl as f32/(n-1) as f32;
    let ac=|k:usize|->f32{let(mut sr,mut si)=(0f32,0f32);for i in k..n{sr+=dr[i]*dr[i-k]+di[i]*di[i-k];si+=di[i]*dr[i-k]-dr[i]*di[i-k];}(sr*sr+si*si).sqrt()/((n-k)as f32)/e};
    let lr=63*SPC; let nr=(lr as f32).sqrt();
    let pk=|pn:&[i8]|->f32{let mut rf=vec![0f32;lr];for c in 0..63{for s in 0..SPC{rf[c*SPC+s]=pn[c]as f32;}}let mut best=0f32;let mut o=0usize;while o+lr<n{let(mut sr,mut si,mut en)=(0f32,0f32,0f32);for i in 0..lr{sr+=dr[o+i]*rf[i];si+=di[o+i]*rf[i];en+=dr[o+i]*dr[o+i]+di[o+i]*di[o+i];}let c=(sr*sr+si*si).sqrt()/(en.sqrt()*nr+1e-9);if c>best{best=c;}o+=32;}best};
    let papr=(0..n).map(|i|dr[i]*dr[i]+di[i]*di[i]).fold(0f32,f32::max)/e;
    let x=[flip,ac(1),ac(8),ac(16),pk(&PNA),pk(&PNB),papr.min(20.0)/20.0,(e+1.0).log10()/5.0];
    let mut xs=[0f32;8]; for i in 0..8 {xs[i]=(x[i]-MU[i])/SD[i];}
    let mut h=[0f32;16]; for j in 0..16{let mut a=0f32;for i in 0..8{let q=W1[j*8+i];if q>0{a+=xs[i];}else if q<0{a-=xs[i];}}h[j]=(A1*a+B1[j]).max(0.0);}
    let mut z=[0f32;5]; for k in 0..5{let mut a=0f32;for j in 0..16{let q=W2[k*16+j];if q>0{a+=h[j];}else if q<0{a-=h[j];}}z[k]=A2*a+B2[k];}
    let(mut bi,mut bv)=(0usize,z[0]); for k in 1..5{if z[k]>bv{bv=z[k];bi=k;}} bi
}
fn main() {
    let mut buf=Vec::new(); io::stdin().read_to_end(&mut buf).unwrap();
    let names=["noise","tone","dsssA","dsssB","wide"];
    let n=buf.len()/4; let nb=if n>=3*8192 {3} else {1}; let blk=(n/nb)*4;
    let mut v=[0usize;5]; for b in 0..nb { v[classify(&buf[b*blk..(b+1)*blk])]+=1; }
    let(mut bi,mut bv)=(0usize,v[0]); for k in 1..5{if v[k]>bv{bv=v[k];bi=k;}}
    if bi==0 { println!("CLEAR: transmit  (votes {:?})", v); }
    else { println!("BUSY ({}): defer  (votes {:?})", names[bi], v); }
}
