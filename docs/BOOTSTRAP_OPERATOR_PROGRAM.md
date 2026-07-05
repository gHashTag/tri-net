# Bootstrap Operator Program — First-N Multiplier Design

**Status**: DESIGN v0 — pre-launch, no implementation
**Addresses**: W7 finding #7 (0% premine leaves no bootstrap capital)
**Anchor**: `phi^2 + phi^-2 = 3`

> **Invariant preserved**: 0% premine. No tokens minted before genesis. No
> insider allocation. No treasury sale. The bootstrap program routes ALL
> subsidy through **on-chain, post-genesis emissions** to nodes that provably
> operated during the bootstrap window.

---

## The bootstrap gap

W7 audit finding #7: Tri-Net has 0% premine. This is a deliberate integrity
choice. It also means:

- No pre-launch treasury to pay hardware manufacturers.
- No pre-launch treasury to subsidize early operators through the
  chicken-and-egg phase (no network → no rewards → no operators → no network).
- Competitors run pre-mines or foundation grants: Helium's Nova Labs raised
  private equity for subsidies ([Fortune 2026-06](https://fortune.com/2026/06/02/andrew-yang-business-acquires-helium-mobile/));
  WeatherXM sold station NFTs to crowdfund inventory
  ([WeatherXM Rollouts](https://rollouts.weatherxm.com/)).

The naive fix — "just do a small premine for bootstrap" — breaks the
invariant Tri-Net's integrity story rests on. This document proposes the
alternative: an **Era-0 emission curve heavily skewed toward first-N
operators**, entirely on-chain, entirely post-genesis.

---

## Design — Era-0 first-N multiplier

### Core mechanic

Standard Tri-Net emission schedule = **base curve `B(t)`**.

Era-0 (first 6 months after genesis) adds a **first-N multiplier `M(n, t)`**:

- `n` = operator's join-order rank at time of node activation (1st, 2nd, ...)
- `t` = time since node activation
- Node's Era-0 reward at time `t` = `B(t) * (1 + M(n, t))`

Multiplier `M(n, t)` decays on BOTH axes:

- **Rank decay** (join order): first operator gets highest boost, N-th gets
  base multiplier, > N gets 0 extra.
- **Time decay** (age of activation): boost decays linearly to zero over 6
  months.

### Suggested calibration — N=100, peak 3x, 6 months

| Rank `n` | Peak multiplier at t=0 | Multiplier at t=3mo | Multiplier at t=6mo |
|----------|------------------------|---------------------|---------------------|
| 1 | 3.0x | 1.5x | 0x |
| 25 | 2.5x | 1.25x | 0x |
| 50 | 2.0x | 1.0x | 0x |
| 100 | 1.5x | 0.75x | 0x |
| 101+ | 1.0x (base) | 1.0x | 1.0x |

Formula (illustrative, subject to modeling):

```
M(n, t) = max(0, (3 - 2*(n-1)/99)) * max(0, (1 - t/180_days))   if n <= 100
M(n, t) = 0                                                       if n > 100
```

Total Era-0 excess emission (integrated over 6 months, N=100 operators): ~150
"operator-months" of base emission distributed among first 100 operators.
Modeled as % of total year-1 emission, this is roughly 6-12% of year-1
emissions concentrated toward early operators — vs. Helium/WeatherXM which
carry those subsidies **off-chain** at founder/investor expense.

### Why this preserves 0% premine

- Zero tokens exist at genesis. Genesis block emits 0.
- All bootstrap subsidy is a redirection of **future emissions to future
  performing operators**, not a pre-allocation.
- If N < 100 operators show up in Era-0, the multiplier simply pays out less
  in absolute terms — nothing is "burned" or "returned" to a foundation.
- No wallet ever holds tokens without having provably operated a node.

---

## Contrast — competitor bootstrap mechanisms

### Helium / Nova Labs — equity-subsidy

- Nova Labs raised traditional VC equity.
- Hardware subsidized: hotspot MSRP historically below true BOM+margin,
  covered by equity dilution and by early HNT premine tail.
- Result: operators onboarded fast; token was diluted; founding entity took
  full economic upside; recent acquisition per [Fortune 2026-06](https://fortune.com/2026/06/02/andrew-yang-business-acquires-helium-mobile/)
  confirms centralized control-plane at all times.
- **Trade-off**: fast bootstrap, low decentralization credibility, insider
  overhang.

### WeatherXM — NFT crowdfunding

- Sold station-manufacturing NFTs pre-launch; NFT holders received a station
  and station rewards ([WeatherXM Rollouts](https://rollouts.weatherxm.com/)).
- Effectively a pre-sale, dressed as an inventory reservation.
- **Trade-off**: technically not a premine, but sells the network before it
  exists; NFT holders are creditors, not operators.

### GEODNET — high-emission burn

- Reported burning ~80% of revenue to prop token price ([CoinGabbar 2026-06](https://www.coingabbar.com/en/crypto-currency-news/geodnet-token-listing-coinbase-june-2026-geod-price-today))
  after emissions ran hot.
- **Trade-off**: reveals bootstrap-through-emission without discipline; without
  time-boxing and rank-boxing, the emission never stops paying "early".

### Tri-Net Era-0 multiplier

- Time-boxed (6 months, hard zero after).
- Rank-boxed (top 100, hard zero after).
- Fully on-chain from genesis (no pre-mint, no NFT, no equity).
- Operators must actually operate — the multiplier applies to reward-earning
  work, not to speculative purchase.

---

## Parameters open for calibration

The `N=100 / 3x / 6-months` numbers above are **DESIGN CANDIDATES**, not
final. Real calibration requires:

1. **Target node count** at end of Era-0 vs realistic operator pipeline.
2. **Total emission-share concentrated in Era-0** — 6-12% is a rough sim;
   exact number depends on base curve `B(t)`.
3. **Rank cliff at n=101** — is a hard cliff acceptable, or should there be a
   tail of `M(n) = 0.5x` for `100 < n <= 200` to smooth incentives?
4. **Time cliff at 6 months** — hard vs quadratic tail.
5. **Multi-node-per-operator prevention** — Sybil resistance: bind rank to
   hardware attestation identity (see `docs/COMPUTE_INTERIM_ATTESTATION.md`
   for attestation layer even at interim tier).

None of these are premine questions. They are all "shape of the first-year
curve" questions.

---

## Sybil defense — why FPGA/PUF attestation matters here

If rank is granted based on "signed a wallet key first" alone, one operator
can register 100 wallets and claim all 100 slots. Rank must be bound to an
attested hardware identity:

- **Bit + Wire realm** — FPGA-attested boards per
  `tri-net-fpga-attestation-workflow` v1.1. Each attested board = one rank
  slot.
- **Compute realm interim tier** — TPM 2.0 EK cert or PUFrt UDID per
  `docs/COMPUTE_INTERIM_ATTESTATION.md`. Each attested compute environment =
  one rank slot in its lane.
- **No attestation, no rank** — non-attested nodes earn `M=0` (base only).

This means bootstrap subsidy REWARDS running actual attested hardware, not
signing many keys. It aligns finding #7 (bootstrap gap) with finding #2
(Compute silicon path) — the same attestation layer solves both.

---

## What does NOT change

- Total year-1 emission ceiling unchanged from base schedule.
- Consensus rules unchanged; multiplier only affects reward accounting.
- 0% premine invariant preserved and provable on-chain from genesis.
- Trinity requirement for full mainnet unchanged (see `docs/COMPUTE_INTERIM_ATTESTATION.md`
  for how interim tier participates without silicon).

---

## Open questions for next loop

1. Simulation of operator-acquisition curves under multiple `(N, peak, window)`
   settings — needs econ modeling notebook (W10 candidate).
2. Legal characterization in TH/SG/UAE/US/EU jurisdictions — does time-boxed
   rank-multiplier trigger any securities regime differently from base
   emissions? Cross-check `docs/REGULATORY_STATUS.md`.
3. Anti-collusion: what stops the first 100 operators from being one entity
   with 100 attested boards? Answer depends on cost-per-attested-board (see
   Interim tier BOM table), and possibly on geographic-diversity rules.

---

## Sources cited in this design

- Helium acquisition, Nova Labs equity-model: [Fortune 2026-06](https://fortune.com/2026/06/02/andrew-yang-business-acquires-helium-mobile/)
- WeatherXM NFT-crowdfunding of stations: [WeatherXM Rollouts](https://rollouts.weatherxm.com/)
- GEODNET emission-burn: [CoinGabbar 2026-06](https://www.coingabbar.com/en/crypto-currency-news/geodnet-token-listing-coinbase-june-2026-geod-price-today)
- W8 competitor watch: `docs/W8_COMPETITOR_WATCH_2026-07-05.md` (in repo)
- W8 decomposed plan (critical triangle): `docs/W8_DECOMPOSED_PLAN.md` (in repo)
- Regulatory status: `docs/REGULATORY_STATUS.md` (in repo)

phi^2 + phi^-2 = 3
