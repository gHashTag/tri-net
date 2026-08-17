# Adversarial Review — "Kill-Memo: Authorisation and Evidence Layer for Counter-UAV"

**Lens: evidence-risk. Posture: refute. Live verification was partially available this session (WebSearch is down; WebFetch works), and it changes the memo's headline finding.**

---

## 0. Headline: the memo's own falsification test #3 was run, and it went against the memo

The memo stakes §7 — its load-bearing section — on "**'FZ-440' — I cannot verify it, and neither, I suspect, can the founder... Any investor should require the date and the quoted article.**" It then builds consequences 1-3, and half of §1 and §6, on the premise that the only applicable legal frame is the Armed Forces countering an air-borne terrorist act.

Verified this session:

- **Федеральный закон от 04.08.2023 № 440-ФЗ exists and is squarely on point.** It amends **11 federal laws** (частная детективная и охранная деятельность 1992; УИС 1993; ГФС 1994; ФСБ 1995; СВР 1996; госохрана 1996; мобподготовка 1997; гражданская оборона 1998; ведомственная охрана 1999; полиция 2011; Росгвардия 2016) and confers the right to **пресекать функционирование** unmanned aerial, surface, underwater and ground apparatus on each of those bodies — including **private security organisations (ЧОО) and ведомственная охрана**. Published at publication.pravo.gov.ru/document/0001202308040025.
- **ПП РФ № 352 от 06.06.2007** verified as characterised (Положение о применении оружия и боевой техники ВС РФ для устранения угрозы террористического акта в воздушной среде). The memo is correct here.
- **ГОСТ Р 59548-2022 "Защита информации. Регистрация событий безопасности. Требования к регистрируемой информации" exists** (approved 13.01.2022) — a national standard that does exactly what §7 says no standard does: specify the composition and content of information to be logged for security events.

So the memo is right that no engagement-record *format* is mandated (verified: 440-FZ contains no reporting/documentation duty and delegates «порядок принятия решения... определяется руководителем» to agency heads), and simultaneously wrong about almost everything it built on top of that.

---

## 1. Claims that SURVIVE

**S1. No mandated record format, schema, retention period or integrity mechanism exists for counter-UAV engagements. — HIGH.**
Verified directly against 440-FZ text: the procedure for taking the suppression decision is delegated to each agency head, with no acts, notifications, or record-keeping prescribed. PP 352 governs conduct, not documentation. This is the memo's strongest and best-evidenced claim, and it is now *better* evidenced than the memo made it.

**S2. A hash chain alone proves sequence-internal consistency, not authorship, not authenticity, and not time. — HIGH.**
Correct as computer science. An unkeyed Merkle chain regenerable by anyone with write access is not tamper-evident against the site's own insider.

**S3. The insider with means and motive is the customer's own operator/duty officer, and the pitch has no answer for that. — HIGH.**
The framing ("name him and you cannot sell; don't and the claim is false") is rhetorically loaded but the underlying threat-model gap is real and unaddressed.

**S4. Most of the schema's fields are owned by other vendors' processes and require their consent. — HIGH (as a risk), MEDIUM (as a blocker).**
Model version and internal confidence really are the classifier vendor's crown jewels. Falsification test #2 (two written interface commitments) is the correct diligence instrument.

**S5. Nulls degrade evidentiary weight, and the schema must permit nulls to deploy. — MEDIUM.**
Directionally right. Overstated as "collapses" (see R7).

**S6. "Identification confidence" from an uncalibrated classifier is not a probability, and recording it to two decimals manufactures false precision. — HIGH.**
The single sharpest technical observation in the memo. Calibration genuinely requires ground-truthed outcomes and genuinely invalidates on firmware change.

**S7. Chain of custody — attested extraction, sealing, handover, an accredited methodology, an expert institution willing to read the format — is unbuilt and is a precondition for any legal value. — HIGH.**

**S8. Insurability is a real and cheap diligence test. — MEDIUM-HIGH.**
"Get a quote, one page" is a good test. The predicted *result* (declined or above seed round) is unsourced (see R12).

**S9. The five falsification conditions in §9 are well-chosen. — HIGH.**
Test #3 has now been partly run and cuts against the memo; that is the correct behaviour of a good test.

---

## 2. Claims REFUTED

### R1. "'FZ-440' is not a citation... I cannot verify it." — REFUTED ON FACT.
440-ФЗ от 04.08.2023 exists, is verifiable in 90 seconds, and is the single most relevant instrument in the entire market. The memo declared the founder's central citation unverifiable and then reasoned from that declaration. A memo whose stated diligence standard is "quote the operative sentence" failed to spend one search on the one law it dismissed.

### R2. "You picked the least accessible slice — this governs only the Armed Forces countering a terrorist act." — REFUTED.
440-FZ gives suppression authority to **ЧОО, ведомственная охрана, ФСИН, полиция, Росгвардия, ГФС, ФСБ, СВР, ФСО**. The memo's own list of "not that legal object at all" examples — refinery, substation, airport perimeter, private security service — are precisely the entities 440-FZ empowers. §7's consequence 2 is inverted: the accessible commercial segment is the one the law newly created, and it is licensed by Rosgvardia (ЧОО licensing), not by FSTEC/FSB.

### R3. "Every plausible end user buys through primes with FSTEC and FSB licences / there is no line item." — REFUTED AS STATED.
A ЧОО or a ведомственная охрана service is not a ГОЗ prime channel. Separately, **187-ФЗ (КИИ)** creates a *statutory* information-security compliance obligation with budgets, mandated event registration, ГосСОПКА reporting, and ФСТЭК Приказ №239 requirements at exactly the object classes named (energy, transport, fuel). The claim "there is no compliance and audit budget in Russia the way there is in a US bank" is asserted with no source and contradicted by an entire regulated ИБ procurement category. *(Confidence in the refutation: MEDIUM-HIGH; the 187-ФЗ regime is well established, but its overlap with engagement records specifically needs the lawyer opinion the memo itself demands.)*

### R4. "'No security clearance' is directly falsified — the records are almost certainly restricted." — REFUTED as a categorical.
It may be true at an MoD site. It is not true at a ЧОО-guarded warehouse or a private logistics yard, which 440-FZ now covers. The memo asserts служебная информация ограниченного распространения / гостайна with **no citation to any перечень сведений**, and the entire §0 "one of the three is false" tell rests on it.

### R5. "If the log is classified it produces no legal value → willingness to pay is zero." — REFUTED as an inference chain.
Classified material is used as evidence in Russian criminal proceedings; УПК РФ ст. 241 provides for closed hearings precisely when state secrets are involved. "Classified" ≠ "inadmissible." The memo's syllogism has a false middle term. *(MEDIUM-HIGH; confirm the УПК article with counsel before relying on it.)*

### R6. "Absent a neutrality mandate, 'log the events of X' is, historically and without exception, a feature of X." — REFUTED by counterexample, in the same channel.
- **Genetec, Milestone** — VMS/evidence-management sold *separately from the cameras*, through security integrators, into air-gapped sites, as sustained standalone businesses recording other vendors' sensors.
- **The entire SIEM/observability category** (Splunk, Datadog, and the Russian analogues) is "log the events of everybody else's X" as a business.
- **OneTrust** — a regulation-timing bet (GDPR), founded 2016, outside every incumbent's workflow, and it won the category. This also refutes §7 consequence 3 ("regulation-timing bets are won by whoever was already inside the workflow") on its own terms. Vanta/Drata repeat the pattern for SOC 2.

"Without exception" is the kind of absolute a specialist breaks in one sentence, and it carries §2's whole conclusion.

### R7. Axon/body-worn cameras are used backwards, and this breaks the memo's "fatal" structural argument. — REFUTED.
The memo's §1 core claim is that the beneficiary is only an oversight layer that would indict the buyer. The body-camera reference class shows the opposite: the durable adoption driver was that footage **exonerates** officers and collapses complaints, which is why police unions moved from opposition to support. If the memo's own analogue produces a buyer-side benefit, then "you are asking a duty officer to buy the instrument of his own prosecution" is not a structural law — it is one of two possible framings, and the memo asserts the unfavourable one without evidence. *(MEDIUM-HIGH — the complaint-reduction literature is mixed in magnitude, e.g. Rialto 2012 vs the Washington DC RCT null result, but the union-position reversal is not in dispute.)*

### R8. §5's argument is unfalsifiable as constructed. — REFUTED as reasoning.
If the record incriminates, you become a witness and die (§5.1). If it exonerates, you certified false innocence and die (§5.3). An argument that reaches the same verdict from opposite outcomes has stopped being evidence and become a stance. At least one branch must be conditional on facts the memo does not have.

### R9. "The C2 vendor already logs 80% of this." — REFUTED as an unsourced number, **and it contradicts §3**.
No source, no method, and internally inconsistent: §3 argues at length that feature provenance, model version, sync error and spoof state *do not exist anywhere in the field*. Both cannot hold. If the fields don't exist, the prime cannot absorb the feature either, and §2's absorption threat evaporates. If the prime has 80%, §3's null catastrophe shrinks. The memo needs to choose, and either choice costs it a section.

### R10. "Most fielded sensors are LAN NTP with unbounded hundreds-of-ms error." — REFUTED on the technical fact.
NTP over a LAN routinely achieves sub-millisecond to low-single-digit-millisecond offset. Hundreds of milliseconds is WAN-over-congested-link behaviour, not LAN. The memo overstates by two orders of magnitude in the one paragraph where it is claiming specialist authority on timing. A sensor engineer would stop reading here.

### R11. "The internal identity field will be a shared night-shift account" — REFUTED as internally inconsistent and unsourced.
§3 describes the operator console as "the most accreditation-frozen machine on the site." Certified Russian АС/КИИ regimes (ФСТЭК Приказ №239, ИАФ measures, ПАК-based identification) mandate individual identification. The memo invokes the accreditation regime when it wants an integration barrier and forgets it when it wants an identity failure.

### R12. Unsourced numbers, in order of load-bearing weight — ALL REFUTED PENDING SOURCE.
- "**80%**" already logged (§2) — no source, contradicts §3.
- "**two sprints**" to replicate (§2) — no source; the estimate is the entire absorption argument.
- "**low hundreds**" of sites; "**3-5 year**" sales cycle (§1) — no method, no registry, no comparable; contradicted in direction by the ЧОО/ведомственная охрана/КИИ populations 440-FZ opens.
- "**a decade** of scandal" for body cameras (§1) — approximately defensible (Rialto 2012 → DOJ BWC PIP 2015) but stated as fact without citation.
- "**milliseconds**" to forge a chain, "**hundreds-of-ms**" NTP error (§3-4) — rhetorical precision, no measurement.
- "**priced above your seed round**" insurance (§5) — no broker, no quote, no comparable; the memo demands exactly this evidence from the founder in §9.5 while supplying none itself.
- "**several had their output excluded**" (§5) — the actual record is more contested: *United States v. Gissantaner* saw STRmix evidence excluded at district level and then **reinstated on appeal (6th Cir. 2021)**; NYC's FST was discontinued after disclosure, not judicially excluded. A specialist would use this to argue the tool-attack playbook mostly *fails*, which inverts the memo's use of it.
- "**0.87**" (§8) is a hypothetical, correctly used, and not a defect.

### R13. "Any export runs through the МТС monopoly (Rosoboronexport)." — OVERSTATED.
Rosoboronexport is the sole state intermediary for finished military products, but ФЗ-114 permits organisations to obtain their own right to conduct ВТС for spare parts, services and support. "Any" is wrong. *(MEDIUM.)*

### R14. "No EU/US/UK customer can buy from you at any price, under any structure, ever." — REFUTED as unfalsifiable.
"Ever," "at any price," "under any structure" are not analytical claims. The directional point (severe, durable, reputationally sticky foreclosure) survives; the absolute does not, and it is doing the work in §6's "the first sale closes the door."

### R15. "You cannot demo." — REFUTED.
VMS, SIEM, forensic and C2 vendors demo on recorded and replayed data as standard practice; acceptance testing (ПСИ) and полигон trials are exactly demo venues; and in the current Russian environment engagement data at energy and transport objects is not scarce. The memo elsewhere insists the C2 vendor already holds 80% of the data — which is a demo corpus.

### R16. "Latency vs integrity" false dilemma. — REFUTED.
The memo offers only "gate the effector" or "best-effort." The standard third answer is an asynchronous, sealed, hardware-timestamped write-once buffer off the critical path — the flight-data-recorder architecture, which is neither gating nor best-effort in the sense that destroys the claim.

### R17. "Your SHA-256 tree has the standing of a .txt file; you need УКЭП under ФЗ-63." — REFUTED as a category error. — MEDIUM-HIGH.
ФЗ-63/УКЭП governs the legal force of electronic *documents* in civil circulation. In criminal proceedings, evidence is evaluated under free-evaluation principles (УПК ст. 17) and logs enter as иные документы / вещественные доказательства (ст. 84) whose weight the court assesses. A GOST-signed record is stronger; the absence of one is not automatic nullity. The memo imports civil-law formalism into a criminal-evidence setting and derives a certification cost structure from it.

### R18. "The one licence you actually need is an FSB СКЗИ licence, and the pitch missed it." — REFUTED AS STATED.
Unkeyed hashing is not obviously a шифровальное (криптографическое) средство under ПП РФ №313; the licence attaches to distribution/maintenance of СКЗИ. A product that ships no crypto, or that integrates a third party's certified СКЗИ under that partner's licence, does not necessarily trigger it. §0's "tell" — the memo's rhetorical opening move — rests on a licensing claim stated with no citation to the ПП 313 list.

### R19. "No GOST, no industry standard, no ministerial order naming required fields... a startup cannot initiate a standardisation programme." — PARTIALLY REFUTED.
**ГОСТ Р 59548-2022** does exactly that for security events generally. The narrow claim (no counter-UAV-engagement-specific format) survives; the categorical framing does not. And ГОСТ Р development is initiated by organisations through ПНС proposals to the relevant ТК — companies write the standards they want. The memo asserts an impossibility that is a routine industry activity.

### R20. "Primes copy rather than buy; state-adjacent acquirers pay book value; name one comparable." — REFUTED as burden-shifting.
The memo supplies zero comparables while demanding one. Russian ИБ M&A (Rostelecom/Solar and its acquisition string, Softline's roll-ups) has repeatedly transacted at revenue multiples, not book value. *(MEDIUM — needs a deal list before either side may assert.)*

### R21. §0 arithmetic. — MINOR BUT TELLING.
"**Four** of the pitch's claimed advantages are 'we don't need X'" — then three are enumerated (weapons licence, clearance, spectrum). In an opening paragraph whose whole function is to establish the author's precision.

### R22. The memo argues against a paraphrase.
Nothing in it quotes the pitch. Every characterisation — "four claimed advantages," "SHA-256 Merkle tree," "no dates given," "FZ-440" — is the reviewer's restatement of a document the reader cannot see. The memo applies a citation standard to the founder that it does not apply to its own account of the founder.

---

## 3. What a decision-maker still needs (and does not have from either document)

1. **The pitch itself.** Not the memo's summary. Every §-level claim about what the founder asserted is currently unfalsifiable.
2. **A lawyer's written mapping of 440-ФЗ (04.08.2023) → subordinate acts.** The law delegates «порядок принятия решения... определяется руководителем» to each of eleven bodies. Those ведомственные приказы are where a record format either exists or will appear. Nobody has read them. This is now the single highest-value hour of diligence available, and it can resolve the deal in either direction: an existing приказ with a prescribed акт/уведомление form falsifies the memo's §7; confirmed absence across all eleven confirms it.
3. **A segment decision, priced.** ЧОО / ведомственная охрана / 187-ФЗ КИИ operator versus ГОЗ prime. These are different licences, different budgets, different classification exposure, different sales cycles, and different insurance answers. The memo collapses them into one and reasons about the hardest; the pitch (as summarised) reasons about the most dramatic. Neither has costed the accessible one.
4. **Whether the engagement record at a *civil* object is classified — with a citation to a перечень**, not an intuition. §6's fatal step depends entirely on this and is currently unsourced on both sides.
5. **Two written interface commitments** (memo §9.2). Unchanged — still the correct and hardest test.
6. **An insurance quote** (memo §9.5). Unchanged, and the memo owes one too before predicting its price.
7. **A trusted-time design that survives an air gap and an on-site GNSS jammer**, with a named mechanism (offline TSA token, HSM-held periodic root, WORM media, one-way anchoring diode) and its cost. Both documents treat this as binary; it is an engineering choice with known options and a real bill.
8. **A build-vs-absorb estimate from someone who has shipped a C2 stack**, replacing the memo's "80% / two sprints" and the founder's implicit "they never will."
9. **A TAM built from registries, not adjectives** — licensed ЧОО count, ведомственная охрана entities, значимые объекты КИИ in the ФСТЭК registry — intersected with counter-UAV deployment. "Low hundreds" and "large market" are currently the same quality of evidence.
10. **Three named Russian comparables**: a security-software company acquired by a state-adjacent buyer, with price and multiple. Settles §8's "no exit" for or against in one page.

---

## Verdict on the memo as evidence

Its diagnostic instrument (§9's five falsification tests) is excellent. Its execution failed its own standard: it declared the founder's central citation unverifiable without attempting verification, and that citation turns out to describe an eleven-body authorisation regime that reverses the memo's market-access conclusion. What survives is a genuine and serious set of technical and evidentiary risks — trusted time, insider threat, calibration, nulls, chain of custody. What does not survive is the "pass" that was derived from the market, legal and competitive sections. **Treat §2-§4 and §8 as a competent engineering risk register; treat §0, §1, §6 and §7 as unsourced advocacy until the eleven subordinate acts have been read.**

Sources used for live verification:
- [publication.pravo.gov.ru — ФЗ от 04.08.2023 № 440-ФЗ](http://publication.pravo.gov.ru/document/0001202308040025)
- [legalacts.ru — текст ФЗ 440-ФЗ от 04.08.2023](https://legalacts.ru/doc/federalnyi-zakon-ot-04082023-n-440-fz-o-vnesenii-izmenenii/)
- [ПП РФ от 06.06.2007 № 352 — Положение о применении оружия и боевой техники ВС РФ в воздушной среде](https://html.duckduckgo.com/html/?q=%D0%BF%D0%BE%D1%81%D1%82%D0%B0%D0%BD%D0%BE%D0%B2%D0%BB%D0%B5%D0%BD%D0%B8%D0%B5+%D0%BF%D1%80%D0%B0%D0%B2%D0%B8%D1%82%D0%B5%D0%BB%D1%8C%D1%81%D1%82%D0%B2%D0%B0+352+2007)
- [ГОСТ Р 59548-2022 — Защита информации. Регистрация событий безопасности](https://html.duckduckgo.com/html/?q=%D0%93%D0%9E%D0%A1%D0%A2+%D0%A0+59548-2022)

WebSearch was unavailable this session (API error); the above were retrieved via WebFetch. Items labelled MEDIUM (УПК ст. 17/84/241, ПП 313 crypto-licensing scope, ФЗ-114 ВТС rights, Russian ИБ M&A comparables) were **not** live-verified and are stated as refutations requiring counsel confirmation — the same standard this review applies to the memo.