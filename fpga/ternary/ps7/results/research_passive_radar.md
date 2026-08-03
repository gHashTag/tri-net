# Adversarial review — "Passive small-drone detection, 2026 landscape"

**Verification performed this session:** I re-fetched and text-extracted the CSIR flyer, the Dedrone RF-360 datasheet, the ONERA/IntechOpen article, the Hidden Level hardware page, the BDEW LTE450 page, the R&S/ATC-Network article, the Defense Daily FAA item, the Phantom Array site, the NDSS DroneID paper page, and the NATO UAS class definition. WebSearch was API-broken for me too; DDG-lite CAPTCHA'd on one query. Where I could not verify, I default to refuted as instructed and say so.

---

## 1. CLAIMS THAT SURVIVE

**S1. Dedrone RF-360: 2.0 km normal / 5.0 km ideal, 24 W typical, 7.0 kg, IP65. — HIGH.**
Verbatim in the datasheet: "Under normal conditions 1.25 mi (2.0 km) for most drones / Under ideal conditions up to 3.1 mi (5.0 km) for specific drones", "24 W (typical)", "15.5 lb (7.0 kg)", "IP65". The analysis also omitted the datasheet's qualifier "Range (line of sight)" — which strengthens its own skepticism, so no harm.

**S2. ONERA DVB-T results as stated. — HIGH.**
Confirmed in the source: F450 quadrotor at 3 km stationary; M600 at 1 km and 5 km; X8/X11 to ~10 km in 2 of 3 trials; 8 channels + 8 Yagis; 0.5 s to ~1 s CPI; 120-130 Hz blade lines. This is the strongest evidence in the document and the analysis reports it accurately. (Two figures attached to it are misused — see R6, R7.)

**S3. CSIR flyer says "Range up to 50 km for Class 2 UAV (based on 4s processing interval)", plus 300/120/80 km for airliner/light utility/fighter, FM resolution better than 1500 m, DVB-T better than 40 m, 3 m/s velocity resolution, 2-3 receiver nodes + 2-3 FM transmitters, 1.5 s antenna-to-track delay at 1 s processing interval. — HIGH as a transcription.**
Every figure verified verbatim. But see R2 and R3: the analysis's gloss on this document is wrong in two places.

**S4. LTE450 passive radar detected a drone "with very high probability up to a range of 1,500 metres". — HIGH as a quote, LOW as evidence.**
Verified German verbatim on the BDEW page. But the page specifies no drone type, no size, no altitude, no geometry, no numeric Pd, no trial protocol. Calling this one of "the two best-documented results" (section 0.2) is not supportable — it is a one-number press announcement.

**S5. FAA five-airport testing: 62% of detection and 33% of mitigation technologies completed the programme; results characterised as "mixed"; per-vendor data not released. — HIGH.**
Verified verbatim in Defense Daily. Caveat in R11.

**S6. One-way vs two-way propagation is why branch (a) is cheap. — HIGH.**
Physics is correct: 1/R^2 for a cooperative emitter vs 1/R^4 for radar. Uncontested.

**S7. Independent, per-vendor evaluation of C-UAS RF sensors is effectively absent in the open literature. — HIGH.**
Supported by S5 and by the fact that every range figure in the tables traces to the vendor or an aggregator.

**S8. Fibre-optic-guided FPV drones emit no control/video RF and are therefore invisible to branch (a) sensors. — HIGH (physics), independent of the cited source.**
The mechanism is unarguable. The *procurement evidence* offered for it is not (R12).

**S9. PCL is the only receive-only modality that can detect a non-emitting airborne target at all. — HIGH.**
Trivially true and correctly stated.

**S10. Zero-Doppler clutter cancellation creates a blind zone for hovering/slow rotorcraft, and blade micro-Doppler is the escape path. — MEDIUM-HIGH.**
Mechanism is standard and ONERA's F450 result is exactly this. Overstated as "the only escape" (R15).

**S11. Patria MUSCL's "hundreds of kilometres" is not attributed to the drone class. — HIGH.**
The analysis's own caveat is correct and is the right reading discipline. (The brochure itself remains a marketing document — see R1.)

**S12. Phantom Array should be treated as unproven. — HIGH, and the analysis under-argues it.**
I fetched the site: no customers, no trials, no measured data, no independent verification. The strongest tell the analysis missed: the band-by-band ranges are **physically backwards** — FM 8-12 km, DVB-T 6-10 km, LTE 5-9 km, **5G NR 12-18 km**. Claiming the *longest* range from the *lowest-power, highest-frequency, most-directional* illuminator (3.5-4.2 GHz beamformed base stations) inverts the link budget. That alone is disqualifying and is better evidence than "self-contradictory because decoys transmit".

**S13. Legal caveat on interception of drone control links. — HIGH as a caveat.** Properly hedged, properly flagged unverified.

---

## 2. CLAIMS REFUTED

**R1. The [V] tag is doing work it cannot do — this is the structural defect.**
"[V] = I read the primary document" is silently used throughout as if it meant "the claim is verified". It does not. The CSIR flyer, Patria brochure, Dedrone datasheet, Hidden Level page and BDEW announcement are **all** marketing or press artefacts with zero measurement provenance: no trial report, no Pd/Pfa, no target definition, no methodology, no date on the CSIR flyer (its PDF metadata says Adobe Photoshop CC 2017, last modified 2023-03-13, despite a "2026" filename). The document calls the CSIR flyer "the single most useful published spec sheet" while dismissing Aaronia's numbers as [C]. Both are unmeasured vendor assertions; only the tone differs. Any conclusion that leans on the [V]/[C] distinction as an evidence hierarchy collapses.

**R2. "NATO Class 2 = 25-600 kg" is wrong. — REFUTED.**
NATO UAS classification is Class I <150 kg, Class II 150-600 kg, Class III >600 kg (verified). "25-600 kg" appears nowhere. Worse: the CSIR flyer says only "Class 2 UAV" — it never states a weight range and never says "NATO". So section 0.2's "CSIR states exactly that [V]" is false on two counts: CSIR states a label, the analysis supplied a definition, and the definition is wrong. The directional argument (a Class 2 UAV is not a quadcopter) still holds — but the sentence as written would not survive thirty seconds with a specialist.

**R3. "2-3 receiver nodes + 2-3 transmitters minimum for 3D" — REFUTED by the cited document itself.**
The CSIR flyer states "**2D Track**" under Typical Performance Specifications. The analysis inverts its own source in two places (section 3.4: "geometry diversity is mandatory for 3D... CSIR's minimum configuration is the shape of the answer"; section 5.2: "2-3 receiver nodes and 2-3 transmitters minimum for 3D and disambiguation (CSIR [V])"). CSIR's configuration delivers 2D tracking. The node-count-for-3D cost argument has no cited support.

**R4. Hidden Level row: specifications are mixed between two products and the modality split is invented. — REFUTED.**
Verified on hiddenlevel.com/products/hardware: **Breaker** = 101 lb, <250 W. **Surge** = 75 lb sensor + 24 lb coprocessor, 335 W + 250 W, and it is **Surge** that carries the 2 degree angle accuracy. The 25 km rural figure sits in a general capability section and is **not attributed to a model or to a modality**. The analysis's "RF up to 25 km (+ passive radar 30 km)" is a fabricated split: nothing on the page says the 25 km is RF. The row as printed is not a citation of that page.

**R5. R&S ARDRONIS "~1.5 km typical / 7 km optimal" is a June 2020 trade item. — REFUTED as current.**
Verified: atc-network.com, published Monday 8 June 2020. In a document titled "2026 landscape", a six-year-old undated trade quote is presented alongside a current datasheet, and then used in section 0.1 to establish that "published ranges cluster at 1.5-5 km". Date it or drop it.

**R6. "Direct-path/clutter sidelobes measured ~37 dB above the region of interest [V]" is a misuse of the ONERA figure. — REFUTED.**
The source gives ~37 dB as the direct-path **sidelobe level at 50 km bistatic range** before cancellation. That is a far-range residual, not the near-range DPI-to-target ratio. Section 3.1 sets it beside "commonly 60-90 dB" as if ONERA had measured a lower value; it did not measure the same quantity. The actual DPI-to-target ratio near zero delay is tens of dB larger.

**R7. "Post-cancellation target SNR 5-7 dB at 50 km bistatic range" is listed under the drone bullet points. — REFUTED as drone evidence.**
Every ONERA drone detection is at 1-9 km. A 5-7 dB SNR at 50 km bistatic range is almost certainly a non-drone target; the analysis never says what target it is. Presenting it inside the drone results implies it characterises them.

**R8. "60-90 dB" DPI/clutter figure has no source. — REFUTED.**
The cited MathWorks page says only "often tens of decibels stronger". "Commonly 60-90 dB" and "classical radar dynamic-range figures ~80 dB" are the analysis's numbers wearing someone else's citation. Same defect: "~50-60 dB of analog/antenna DPI suppression before the digital ECA does the remaining 30-40 dB" [I] is an invented budget, and it is probably backwards — practical Yagi front-to-back is ~20-25 dB, while published ECA/CLEAN implementations routinely report 40-70 dB of *digital* cancellation.

**R9. "12-bit ADC is a binding limit" is refuted by the document's own citation. — REFUTED as stated.**
74 dB SQNR is instantaneous over the Nyquist band; a 7.6 MHz correlation over a 0.5-1 s CPI supplies 60-70 dB of coherent processing gain on top. The analysis compares 74 dB of ADC dynamic range against a 60-90 dB DPI ratio as if they were commensurate — they are not. And its own strongest counterexample sits three paragraphs later: the IEEE Spectrum KrakenSDR build uses **8-bit** RTL-SDRs and still tracks airliners. The real limits the analysis lists (AGC headroom, zero-IF spurs, LO reciprocal mixing, channel count) are correct; the bit-depth framing is not.

**R10. "$400 of hardware gets kilometres" — REFUTED, contradicted by its own evidence.**
The 1.3-3.7 km DroneID results it cites were obtained with a USRP B210 (street price roughly $1,300-2,300), and DroneID decode needs ~10 MHz of coherent bandwidth, which rules out the $30 RTL-SDR class outright. No source is given for $400. The claim is off by roughly 3-5x against its own citation.

**R11. "Only 62% of detection technologies completed the test programme" is used to imply detection failure. — PARTIALLY REFUTED.**
The figure is real, but "completed the program" is a participation statistic, not a performance one — withdrawal, contracting, scheduling and siting all produce non-completion. The FAA official's word was "mixed", which the analysis quotes correctly; the 62% should not be read as a 38% failure rate. Also, the source says **FAA**, five domestic airports; "FAA/TSA" adds an agency the citation does not.

**R12. "This is now an explicit procurement fact, not a theory" — REFUTED.**
The sole support is a single post on thedefensecircuit.com, tagged [R], for both the Israeli MAFAT call and the UK Defence Innovation request. Neither primary source (MAFAT's own call, UK DI's own request) was retrieved. One low-authority blog post does not convert a claim from theory to "procurement fact". The underlying physics (S8) stands on its own and does not need this citation — which is exactly why the rhetorical upgrade is gratuitous.

**R13. "Russian deployment at scale dates from early 2024 [R]" — REFUTED, no source at all.**
No citation is offered anywhere in the document for this. First reporting of Russian fibre-optic FPVs is generally placed in spring 2024 with scaled employment reported considerably later. "At scale, early 2024" is unsupported as written.

**R14. "~0.01 m^2 RCS class at microwave [R]; better at UHF" — REFUTED as the load-bearing number it is.**
This single unsourced figure carries the entire feasibility argument of section 5. No frequency, no aspect, no measurement, no reference. A 7-10 inch quad at 450-700 MHz (lambda 0.43-0.67 m) is in the Rayleigh-to-resonance transition where RCS swings by tens of dB with aspect and frequency, and "better at UHF" is asserted with no number at all. The 30 dB gap to the RIT study's 10 dBsm target is arithmetically correct (10 - (-20) = 30) but rests on a figure with no provenance. The whole fibre-FPV section inherits this.

**R15. "The only escape is micro-Doppler blade lines" — REFUTED as absolute.**
A hovering multirotor is not exactly zero-Doppler (station-keeping, wind, drift), clutter notches are finite in width, and body-return detection outside the notch, range-only detection, and long-CPI residual-clutter suppression are all live paths. The blade-line route is the *demonstrated* one, not the only one.

**R16. Doppler-migration arithmetic is a factor of two low. — REFUTED.**
At 600 MHz (lambda = 0.5 m), 10 m/s^2 gives a monostatic Doppler rate of 2a/lambda = 40 Hz/s, not "~20 Hz per second". The analysis used the one-way form. Bistatic geometry reduces it by cos(beta/2)cos(delta), so 20 Hz/s is a favourable-geometry case presented as the general one — it makes the integration-time problem look easier than it is. Relatedly, "compute cost goes up quadratically-ish with search dimensions" [I] is hand-waving; cost scales with the number of acceleration/keystone hypotheses searched, roughly linearly per added CAF.

**R17. "56 MHz covers every terrestrial illuminator that matters" — REFUTED for the architectures the document itself holds up as state of the art.**
True per channel; false per system. The AD9361's two RX chains share LO synthesis, so one chip cannot simultaneously cover FM (88-108 MHz) and DVB-T (470-790 MHz) — which is precisely what Hensoldt TwInvis (FM + DAB + DVB-T, multi-transmitter) and Patria MUSCL (FM + DVB-T/T2, multistatic) do, and both are cited approvingly two sections earlier. Multiband/multi-transmitter diversity, not per-channel bandwidth, is the constraint the analysis waved away.

**R18. "No credible published drone detection at useful range on AD9361-class hardware for branch (b)" — REFUTED as a conclusion; survives only as "I did not find one".**
The method note concedes WebSearch was broken and that MDPI, IEEE, NATO STO, Wiley and ResearchGate all 403/402'd. Those are exactly the venues where such a result would be published, and four of the five reported-only results (Brno DVB-T2, Warsaw PaRaDe, Sapienza/Alcala, NATO STO) have **unknown receiver hardware** because their papers could not be opened. Concluding absence from a search that could not run is not permissible. The same defect applies verbatim to "no public evidence exists of a PCL system detecting a fibre-optic FPV drone at operational range" and "No published Starlink-PCL drone detection exists" — both are negative universals asserted from a broken search.

**R19. "Published ranges cluster at 1.5-5 km" (section 0.1) — REFUTED as a description of the evidence.**
The document's own table has six rows: 2-5 km, 1.5-7 km, 5-80 km, no figure, 25 km, and a market-context row. Two rows are not a cluster. The honest statement is: *the only two vendor figures with traceable wording are 1.5-5 km; the rest are unsourced or absent.* The distributional language implies a sample that does not exist.

**R20. "DroneShield publishes no numeric range — [V] absence of a figure; notable" — REFUTED as a tagging category.**
You cannot mark an absence [V] ("I read the primary document") in a session that reports multiple unreachable vendor sites, a broken search tool, and one vendor site refusing connections outright. The same absence is tagged [C] for Hensoldt in the next table. The taxonomy is applied inconsistently to the two absences, and neither is [V].

**R21. "3GPP TR 38.765 (Rel-20) carries ISAC for NR" — REFUTED pending a spec number.**
TR 22.837 (Rel-19 ISAC use cases, SA1) is real. I could not verify TR 38.765; the 38.7xx range is not where RAN study reports normally sit. Default to refuted: cite the actual TR/WI number or drop it. This matters because it is the only forward-looking timeline anchor in the document.

**R22. "240 MHz IBW immediately rules out the AD9361 class for this branch" — REFUTED as stated.**
240 MHz is required for the RIT study's *0.62/0.88 m imaging resolution*. Detection does not require full-bandwidth exploitation. The correct statement is that AD9361 cannot reproduce that study's imaging geometry — not that it is ruled out of Starlink-based sensing generally. (The rest of the Starlink section's skepticism is sound.)

**R23. Silentium MAVERICK M8 "3-7 km drones / 20 km aircraft" — REFUTED as sourced.**
The vendor site was unreachable for both of us. Chasing the number, the trail I could reach terminates at a third-party aggregator listing, not at Silentium. The analysis's own tag [R] "vendor-derived" overstates this: nothing establishes the vendor ever said it. "USSOCOM tested" appears in the table with no citation whatsoever. And "drones" carries no size class — the same sin the analysis correctly punishes CSIR-adjacent claims for.

**R24. "Acoustic (the only passive modality with a routine fibre-FPV detection story)" — REFUTED, self-contradicting.**
The same sentence lists EO/IR as fielded and "infrared specifically credited to Ukrainian practice". EO/IR is passive. Either acoustic is not the only one, or the sentence means something narrower than it says. No source is given for either.

**R25. NDSS citation is mis-titled. — REFUTED (minor but checkable).**
The paper is "Drone Security and the Mysterious Case of DJI's DroneID" (Schiller et al., NDSS 2023), verified. "Dissecting DJI's DroneID" is not its title. Separately, I could not confirm the 1.3 / 1.5 / 3.7 km per-airframe reception distances from the paper's landing page; they may be in the PDF, but they are currently the load-bearing number for the document's central "settled" claim (section 4, branch (a)) and remain untraced.

**R26. The fibre-FPV engagement geometry (10-100 m AGL, 5-20 km standoff) is assumed, then used as the yardstick. — REFUTED as circular.**
Nothing establishes 5-20 km as the required standoff. A site-defence PCL node sits at the defended site, and the threat must close on that site; the operational requirement could as easily be 2 km of warning. The analysis picks a geometry, measures published PCL against it, and reports a shortfall that is partly an artefact of its own assumption.

**R27. "Cost class: research prototype in the tens of thousands; fielded node in the hundreds of thousands [I]" — REFUTED.**
Zero anchor. No quote, no comparable, no bill of materials. This is the single number a budget holder would actually act on and it is the least supported number in the document.

**Minor, but a specialist will ask:** FM 200 kHz gives c/2B = 750 m while CSIR states "better than 1500 m" for FM — the 2x gap (bistatic geometry factor) is never reconciled, and both are quoted approvingly. Blade lines are given as "100-150 Hz generally" where the source says 120-130 Hz. "Position needs AoA from >=2 sensors" yields 2D position only, in a document that elsewhere insists on 3D. Drone EIRP "~20-30 dBm" is unsourced and conflates conducted power with EIRP.

---

## 3. WHAT A DECISION-MAKER STILL NEEDS AND DOES NOT HAVE

1. **A target definition.** Not one range figure in the document — including the two it calls best-documented — is paired with a stated target RCS, size, airframe, altitude, aspect and flight state. "3-7 km against drones" and "1500 m" are uninterpretable without it. Demand: RCS in dBsm at the illuminator frequency, airframe model, AGL, hover vs transit.
2. **Pd and Pfa at a stated range, over a stated number of runs.** Every number here is a maximum-observed or a brochure figure. ONERA's "2 of 3 attempts" is the only place in the entire document where a denominator appears — and it is the least flattering number in it. Without Pd/Pfa curves there is no basis for comparing any two systems.
3. **A measured RCS for the actual threat.** A 7-10 inch FPV quad at 450-700 MHz, measured, across aspect. Every conclusion in section 5 is a function of this one unsourced number. The NATO STO Parrot AR Drone RCS work the document could not open is the obvious starting point.
4. **The 2D/3D question, answered.** CSIR's cited configuration is explicitly 2D. What node count, baseline geometry and time-sync budget actually produce a 3D track good enough to cue an effector? The document asserts a cost driver it did not source.
5. **Illuminator survivability, quantified.** The document rightly praises the utility-owned LTE450 choice, then never asks the operative question: what is the coverage geometry, EIRP and tower density of LTE450 (or the local DVB-T mux) *at the specific site to be defended*? PCL performance is a property of the site-transmitter-target triangle, not of the receiver. No site study, no answer.
6. **Real acquisition costs.** Vendor quotes for a Hidden Level Breaker, a Silentium MAVERICK M-series node, and a Patria MUSCL minimum configuration, with node counts for one site. The document's cost estimate is invented.
7. **The primary sources it could not open.** MDPI Drones 9(1):76 (survey), NATO STO MP-MSG-SET-183-13, IET RSN 10.1049/rsn2.70092 (LTE450), IET RSN 2019.0309 (Sapienza/Alcala airport), and the Brno DVB-T2 paper — with specific attention to **what receiver hardware each used**, since the document's central hardware conclusion rests on their absence.
8. **Primary procurement documents**, not blog coverage: the MAFAT call text and the UK Defence Innovation request text, with their actual stated requirements and ranges.
9. **An end-to-end kill chain, not a sensor.** Even the document's own section 5 concedes the effector problem against fibre drones is unsolved. A sensor that detects at 1.5 km with a 1.5 s track latency against a 30 m/s target buys ~50 s of warning and nothing else. What is the response that warning triggers, and what is the minimum detection range that makes that response work? That number should drive the whole procurement, and it is nowhere in this document.
10. **Jurisdiction-specific legal advice**, which the document correctly flags as unverified and which remains unverified.