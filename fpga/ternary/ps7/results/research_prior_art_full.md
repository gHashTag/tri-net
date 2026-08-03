# Adversarial review — lens: prior-art. Verdict: the survey's scholarship is broadly sound; its two headline conclusions are not supported by its own evidence.

I independently verified the load-bearing citations (Google/FPO patent records, arXiv, the cited IRAM page, GitHub API). Two verified facts overturn the document's central verdict.

---

## 1. CLAIMS THAT SURVIVE

**S1 — US 4,270,179 (Ricoh) is real, on point, and expired. [HIGH — verified]**
Title, assignee (Ricoh Company Ltd.), filing 1979-06-29, grant 1981-05-26 all confirmed. Confirmed text: *"The tern operative (i.e., tern(R)) is equal to the sign of R unless R=0, in which case the tern (R)=0"* and *"Rather than assigning zero value a polarity, which would tend to create a bias, the signum operation is replaced with the 'tern' (for ternary) operation."* Pre-URAA 17-year term from grant → expired 1998. The "most damaging prior art" label is earned.
*Caveat:* the doc's quotation *"the 8-bit multiplication is replaced by a 1-bit multiplication which is much simpler"* does **not** match the retrieved text, which reads *"A real 8-bit-by-8-bit multiplication of R and S is replaced by a simple exclusive OR operation on the sign of R and the sign of S."* Confirm verbatim before it goes on a slide. Also note scope: this is an adaptive-gradient (LMS) patent — ternary applies to the *operands*, not a stored weight bank.

**S2 — US 7,395,291 and the 320M figure. [HIGH — verified]** Univ. of Hong Kong, filed 2004-02-24, granted 2008-07-01. The number is in the patent: *"about 320 million by one estimate."* The doc's hedge "(expired or near)" is wrong in the safe direction — 20 years from filing means definitively expired since Feb 2024.

**S3 — US 2026/0195581 claim 1 is quoted accurately. [HIGH — verified]** I retrieved claim 1 verbatim; it matches. (Its *use* is overreached — see R4.)

**S4 — Tridgell et al. numbers. [HIGH — verified]** arXiv:1909.04509 confirms "122 k frames per second, with a latency of only 29 us," "90% of the operations in convolutional layers," 90.9% CIFAR10, AWS F1.

**S5 — The correlator-efficiency correction is the document's best contribution. [HIGH — verified]** The cited IRAM Table 6.1 confirms 0.64 / 0.81 / 0.88 at Nyquist and 0.74 / 0.89 / 0.94 at 2x. The doc is right that 0.88 is the **four-level (2-bit)** row and that "0.81/0.88 for 3-level" conflates two rows. This single sentence is worth the document.

**S6 — Scope conditions on eta_Q. [MEDIUM-HIGH]** Zero-mean band-limited jointly Gaussian, weak-correlation limit, correct thresholds/weights, per-sample, and "Van Vleck removes bias, not variance" — all correct as stated. sqrt(2/pi) = 0.798 ≈ 0.98 dB for the hybrid case: arithmetic checks, not independently sourced.

**S7 — The weights-vs-data distinction (§2 point 5). [HIGH]** Correct, and the most useful analytical move in the paper: the 1.96 dB figure prices *data* quantisation and does not price ternary *weights*. A pitch that quotes it for weights is wrong.

**S8 — Two of the four named GNSS IP products exist. [HIGH — verified]** Integre Technologies IP-GPS-BTC12 ("12-Channel C/A code baseband tracking core designed to be used in FPGA implementations") and GNSS IP.tech Quad-Rx (released by Sept 2018). Existence survives; *competitorhood* does not (R9).

**S9 — The framing advice. [MEDIUM]** "Stop claiming the arithmetic; cite Cooper 1970 and Weinreb 1963 yourself; claim the measured engineering result" is sound regardless of the evidentiary problems below.

---

## 2. CLAIMS REFUTED

**R1 — "Freedom to operate is broadly good... Those two facts are the same fact." REFUTED. Most serious defect in the document.**
FTO and patentability are different searches with different methodologies, and only the latter was performed. Expired 1979/2004 art removes nothing from later narrow grants. The doc's own table contains at least two **in-force** patents whose assignees it failed to resolve — each took me one fetch:
- **US 12,231,283 — assignee Rockwell Collins, Inc.**, filed 2023-08-08, granted 2025-02-18, "System and method for using FPGA look-up table as quadrature digital correlator." Claim 1: reference / secondary-reference / in-phase / quadrature registers coupled to lookup tables that "output correlation results based on the Boolean inputs." That is FPGA-LUT-as-correlator, in force to ~2043, held by an avionics prime. The doc lists assignee as "not verified."
- **US 12,566,949 — assignee Inha University Research and Business Foundation**, filed 2023-04-20, **granted 2026-03-03**, "Ternary neural network accelerator device and method of operating the same." In force to ~2043. The doc lists assignee as "-".

No claim charts, no CPC-scoped search, no non-US jurisdictions (CN/KR/EP/JP, where ternary-accelerator filing is heaviest). A decision-maker acting on "FTO is broadly good" is exposed.

**R2 — "Every FPGA synthesiser since the mid-1990s refuses to infer a DSP48/multiplier block for a constant coefficient in {-1,0,+1}" / "it is what FPGA synthesis tools already do automatically." REFUTED, three ways.**
(a) Anachronism: FPGAs had no hard multipliers in the mid-1990s. Virtex-II 18x18 multipliers are 2001; DSP48 is Virtex-4, 2004. (b) "Refuses" is false — `use_dsp` / `USE_DSP48` attributes and pragmas force DSP mapping; behaviour is directive-dependent. (c) Fatal to the argument: constant folding applies only to **compile-time constants**. In a ternary NN accelerator or a reconfigurable correlator, weights are **runtime-loaded registers**; no synthesiser folds them, and the tool must emit precisely the negate/zero/select structure being claimed. The doc's headline dismissal never reaches the case in dispute. No source is offered for the claim.

**R3 — "Open FPGA accelerators (TernaryCore, TernFPGA, Ternary-NanoCore)" as evidence of industrialisation and as prior art. REFUTED. [GitHub API, checked 2026-08-02]**
- `Neumann-Labs/ternfpga` — created **2026-06-08**, 0 stars, 0 forks.
- `Ternarycore/ternarycore` — created **2026-04-05**, 6 stars, 1 fork, last push 2026-08-02 (minutes before my query).
- `zahidaof/Ternary-NanoCore` — created **2025-11-27**, 9 stars, 1 fork.

Three solo/hobby repos, all under ~9 months old, are placed in a section titled "the same trick, relabelled" beside AMD-maintained FINN and Microsoft BitNet. Two consequences. (i) They cannot support the "65-75 years of prior art" frame — they are *contemporaneous competition*, which is a different and weaker argument. (ii) As patent prior art they bar only filings effective after ~Nov 2025 / Apr 2026 / Jun 2026; the doc never states the buyer's priority date, so it cannot know they apply. And the load-bearing verbatim string used to prove a pitch's claim is already public — "sign-and-zero select, one 6-LUT, no hardware multiplier" — comes from the **0-star repo created in June 2026**, with no URL, no author, no commit date given. Recommendation #1 then tells the buyer to benchmark against "TernaryCore," a 6-star repo, as published state of the art.

**R4 — "That last one is the exact 'sign-select, skip-on-zero' mechanism, already claimed" (US 2026/0195581). PARTLY REFUTED.**
Claim 1 is quoted correctly, but: (a) a **pending application confers no exclusion right** — it cannot be infringed, and claims routinely narrow in prosecution; using it in an FTO verdict is a category error. (b) The claim is narrow — 2D systolic array + saturating accumulator + clock gating on zero + "to perform transformer inference **in an all-silicon domain**." A correlator is not transformer inference; that limitation plausibly puts an FPGA correlator outside it entirely. (c) Dates are anomalous: filed 2025-12-29, published 2026-07-09 — 6.4 months against the normal 18. Either early publication was requested or there is an unstated priority chain that moves the effective date. The doc identifies no priority. (d) No applicant/assignee appears on the record I retrieved; a filing titled with Microsoft's product name and no named assignee should be resolved before anything is concluded from it.

**R5 — "FreePatentsOnline returns 204 US patents and applications... The space is crowded." REFUTED as evidence.**
No query string is given, so it is unreproducible. FPO counts are relevance-ranked full text, not boolean-precise: I ran `ternary AND correlator` on the same engine and got **82,342** matches, of which roughly three of the top five are genuinely about ternary correlation. A raw FPO hit count carries no information about crowding. The right instrument is a classification-scoped count (G06N3/063, G06F7/544, H04B1/7075) with the query printed.

**R6 — "4-level ~0.996 sigma with a weighting factor near 3.3." REFUTED on the number.**
The cited IRAM Table 6.1 gives four-level as **n=3, v0=1.00 sigma** and **n=4, v0=0.95 sigma**, both eta=0.88 (footnote: 0.87 if low-level products deleted, Plateau de Bure). The classical TMS optimum is **n=3.3359, v0=0.9816 sigma**. "0.996" matches neither. Related sourcing slip: the precise decimals 0.6366 / 0.8098 / 0.8825 are said to be "verified against IRAM Table 6.1," but that table carries only 0.64 / 0.81 / 0.88. This matters because the document's own thesis is that a buyer catches exactly this class of error.

**R7 — The GNSS dB ladder (1.96 / 0.55 / 0.165 / 0.05 / 0.015 dB) and "the GNSS community quotes the same table." REFUTED as sourced fact.**
Zero citation for the 3-, 4-, 5-bit values. The first two are just -10log10 of the doc's own 0.6366 and 0.88 — restatements, not corroboration from a second community. Worse, the two tables are dimensionally mixed: one runs 2/3/4-*level*, the other 1/2/3/4/5-*bit*. **Three-level is not a bit count**, so they cannot be aligned row-for-row as claimed. And GNSS quantisation loss depends on AGC setpoint, loading factor, and sampling rate relative to bandwidth, degrading sharply under narrowband interference — none of which is stated.

**R8 — "For codes that are already {-1,+1}... that mismatch is exactly zero." REFUTED as over-general.**
(a) **CBOC** (Galileo E1 OS) and **TMBOC** (GPS L1C) are weighted sums of BOC(1,1) and BOC(6,1) — genuinely multi-level; **AltBOC** (E5) likewise. The claim fails on the two newest civil signals. (b) "Exactly zero" holds only for ideal rectangular chips, chip-aligned sampling and no front-end filtering; the true matched filter for a band-limited received signal is not a ±1 sequence, and fractional-chip alignment reintroduces mismatch. (c) **Carrier wipe-off is omitted entirely** — the local complex-carrier multiply is the other half of every correlator channel, is not ±1, and carries its own coarse-quantisation loss. A vendor briefed on this section would still be blindsided.

**R9 — The four "competitors." REFUTED as a competitor set; half unverified.**
Verified: Integre IP-GPS-BTC12, GNSS IP.tech Quad-Rx. **Not verified: T2M-IP's GNSS core and, pointedly, CTTC "G-ACQ-ST" / "G-TRK-ST"** — I found no trace of those part names; CTTC's known GNSS output is **GNSS-SDR, GPL-licensed software**, not a licensable RTL core, so that entry may be a category error. Alone among the document's claims, none of the four carries a URL. More fundamentally, all four are **GNSS receiver basebands** — they compete only if the product is a GNSS baseband, which the document never establishes because it never says what the product is.

**R10 — "The competitive baseline is... the FFT... any pitch that benchmarks against a time-domain correlator has chosen a strawman." REFUTED as a general claim.**
True for GNSS cold-start acquisition over a 2-D Doppler/code grid. False for: tracking loops (correlators, always, post-acquisition); radio-astronomy XF correlators and VLBI, where lag correlation is the deployed architecture; UWB / 802.15.4z ranging; any low-latency or continuous-detection application where FFT block latency and boundary effects disqualify it; and short-template / high-channel-count regimes where FFT overhead dominates. Recommendation #4's "pick FFT-based acquisition as the baseline, deliberately" is unjustified without the workload and could hand a reviewer an irrelevant comparison.

**R11 — "Used for the first interstellar-molecule (OH) detection." REFUTED.**
Weinreb's spectrometer produced the first *radio* detection of an interstellar molecule (OH, 1963). CH, CH+ and CN were detected optically between 1937 and 1941. As written the sentence is wrong, and it is exactly what an astronomer in the room corrects.

**R12 — Citation hygiene, multiple. REFUTED individually, corrosive collectively.**
Wolff, Thomas & Williams (1962) appeared in **IRE** Trans. Information Theory; IEEE Trans. Inf. Theory did not exist until 1963. **LUTMUL is ASP-DAC 2025** (Xie, Li, Diaconu, Handagala, Leeser, Lin — Northeastern/Adobe), not "LUTMUL 2024." Ipatov ternary sequences entered the standard in **802.15.4a (2007)**; 802.15.4z (2020) is a later amendment. "TENET 2024" in this space is unverified. None is fatal, but the document's entire rhetorical strategy is specialist-grade sourcing, and these are the errors that erode it.

**R13 — "Roughly 65-75 years... independently established in at least four communities." REFUTED as stated.**
From the doc's own earliest citations (Van Vleck 1943, Faran & Hills 1952) the span is 74-83 years; "65-75" is unanchored to anything in the document. "Independently" overreaches: sonar detection theory and radio-astronomy spectroscopy rest on the same Gaussian-clipping analysis (Van Vleck), and the 2015-17 ML wave is a rediscovery that cites the quantisation literature — not an independent establishment.

**R14 — Uncited assertions doing load-bearing work in the verdict table.**
"Vendor app notes" (no vendor, no note number, no date) is one of two supports for the verdict row "Correlation without multipliers on FPGA — not novel." "GPS correlator ASICs since the 1980s" is supported only by a 1990s part. "EHT-HOPS and the VLBI literature both use eta_Q ~ 0.88" — no citation. SnapTrack US 6,208,291 / US 7,127,351 and the phrase "hundreds of thousands of correlators" — no citation; not verified by me. ALMA Memo 407's "~4% efficiency loss from a 2 dB gain slope" — memo linked, extracted number unverified.

**R15 — Internal inconsistency.**
Section 2 is the longest and best-sourced section and is entirely about **data** quantisation — and its own point 5 states that penalty "applies to quantising the DATA, not the weights." Roughly 40% of the document argues a metric it says is inapplicable, while the metric that *is* applicable (template-mismatch loss) gets three sentences, no number, no bound, and no citation.

**R16 — The survey is not complete; the omissions are the ones a specialist names first.**
Missing: **commercial multiplierless correlator ICs** (TRW LSI Products TMC2220/TMC2221, Stanford Telecom STEL-3310 / STEL-2000A, the Harris/Intersil line) — 1980s-90s silicon that *is* the multiplierless correlator and is closer commercial prior art than anything in §5; **canonical signed digit / multiple constant multiplication** (§5 cites distributed arithmetic but not CSD/MCM, which is more directly on point for {-1,0,+1} taps); **Budisin's efficient Golay correlator (1991)** and complementary-sequence add/subtract-only correlators; **sign-LMS / sign-sign LMS** (Lucky 1966 onward), the adaptive-filter lineage the Ricoh patent actually sits in; **systolic correlator arrays** (Kung, 1982), relevant to the "PE array" half. Also absent: any CPC-classified search at all.

**R17 — "Distributed arithmetic... defeats broad claims generally" and "patentability of the core idea is effectively zero." REFUTED as legal statements.**
Patentability is assessed claim-by-claim under 102 (all elements in one reference) and 103 (obviousness with motivation to combine). No single 1974 reference defeats claims "generally." And no prior-art survey can pronounce patentability without claim language to read the art against — the document has none, because it never saw the pitch's claims.

---

## 3. WHAT A DECISION-MAKER STILL NEEDS

1. **What the product is.** The document reviews "a pitch" it never describes: no application, no workload, no channel count, no bandwidth, no target device, and — decisively — no statement of whether weights are compile-time constant or runtime-loaded. Every downstream conclusion turns on that: which competitors apply, which baseline is fair, whether synthesis folds the coefficient (R2), whether the 2/pi figure is even in scope (R15).
2. **The priority date.** Without it, none of the 2025-2026 art (three GitHub repos, US 12,566,949, US 2026/0195581) can be classified as prior art versus contemporaneous competition. One line of input flips half the verdict table.
3. **A real FTO opinion.** Claim charts against in-force claims, starting with **US 12,231,283 (Rockwell Collins)** and **US 12,566,949 (Inha University R&BF)**; CPC-scoped searching (G06F7/544, G06N3/063, H04B1/7075, G01S19/24 and /29); and CN/KR/EP/JP. The present document is a novelty search wearing an FTO conclusion.
4. **One measured number.** The doc's own recommendation #1 is correct and entirely unfulfilled: ternary taps per LUT/CLB, Fmax, correlations/s/W on a named part, against DSP48 correlation, an FFT engine of equal function, and FINN — with the workload fixed first. There is not a single measured result anywhere in the analysis.
5. **A template-mismatch loss model.** The one loss figure that actually prices ternary *weights* is unquantified. Needed: normalised-inner-product loss versus sparsity budget for the intended template class, plus the resulting sidelobe/PSLR degradation. Without it, nobody can say whether this costs 0.1 dB or 3 dB.
6. **Whether the GNSS frame is even correct.** Two of four named competitors are unverified, all four are GNSS basebands, and the FFT-baseline recommendation is GNSS-acquisition-specific. If the product is not a GNSS receiver, §3 and the competitor list are the wrong analysis and must be redone.
7. **Verbatim sources for the load-bearing quotes**: the "sign-and-zero select, one 6-LUT, no hardware multiplier" string (repo URL and commit date), the FPO query behind "204," the vendor app-note numbers, and the Ricoh sentence as the document renders it — which does not match the text I retrieved.

**Net:** the historical survey (§2, §4, §5) is largely defensible and the Ricoh patent is a genuine kill shot against novelty. The two conclusions a buyer would act on — "FTO is broadly good" and "synthesis tools already do this automatically" — are both refuted, the first by patents inside the document's own table.