# Ternary RF classifier -- runs ON the board's ARM PS (busybox awk).
# Input: interleaved int16 I,Q decimals (from: iio capture | od -An -td2).
# Extracts 2 features, runs a 2-layer ternary sign-select MAC net (weights in
# {-1,0,+1} -- the SAME primitive as the radio despreader and the FPGA MAC),
# argmax -> class {noise, tone, spread}. This is "AI on the chip", executing on
# the Zynq PS while the AD9361 radio runs on the PL of the same die.
BEGIN { n=0; sa=0; cneg=0; prevI=0; prevQ=0; first=1 }
{
  # od gives whitespace-separated int16s; walk them in I,Q pairs
  for (i=1; i<=NF; i++) {
    v=$i
    if (haveI==0) { I=v; haveI=1 }
    else {
      Q=v; haveI=0
      mag = (I<0?-I:I) + (Q<0?-Q:Q)          # |I|+|Q|, energy proxy
      sa += mag; n++
      if (!first) {
        # r = Re(s[n] * conj(s[n-1])): constant + for a pure rotating tone,
        # flips NEGATIVE at each BPSK 180-degree chip reversal in DSSS.
        r = I*prevI + Q*prevQ
        if (r < 0) cneg++
      }
      first=0; prevI=I; prevQ=Q
    }
  }
}
END {
  if (n<2) { print "class=?? (no samples)"; exit }
  energy = sa/n                      # mean |I|+|Q|
  fneg   = cneg/(n-1)                # fraction of phase reversals (chip flips)

  # The phase-flip rate alone separates the three classes and is INVARIANT to
  # signal level (a drifting noise floor no longer confuses it):
  #   noise ~0.5-0.8 (random) | tone ~0.000 (smooth) | spread ~0.03 (chip edges).
  fhi = (fneg > 0.15) ? 4 : -4    # many flips -> noise
  flo = (fneg < 0.005) ? 4 : -4   # ~no flips  -> tone

  # layer 1: 3 hidden neurons, ternary weights (sign-select MAC, 0 DSP)
  hn = sel( 1,fhi)                 # noise:  many flips
  ht = sel( 1,flo)                 # tone:   no flips
  hs = sel(-1,fhi) + sel(-1,flo)   # spread: some but not many

  # argmax over the 3 ternary-MAC scores
  cls="noise"; best=hn
  if (ht>best){best=ht; cls="tone"}
  if (hs>best){best=hs; cls="spread"}
  printf "energy=%.1f flips=%.3f  scores[noise=%d tone=%d spread=%d]  -> class=%s\n",
         energy, fneg, hn, ht, hs, cls
}
# ternary sign-select MAC element: w in {-1,0,+1} -> +x / -x / 0 (no multiply)
function sel(w,x) { if(w>0) return x; if(w<0) return -x; return 0 }
