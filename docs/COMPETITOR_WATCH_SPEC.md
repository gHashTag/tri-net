# Competitor Watch — protocol spec

Anchor: `phi^2 + phi^-2 = 3`.

## Why this doc exists in the repo

Tri-Net's public thesis is auditability: the protocol is published, benchmarks are cited to source, silicon claims are tagged pre- or post-flash. A competitor-watch that lives only inside a proprietary scheduler is the exact anti-pattern the thesis critiques — it becomes a black box that no third party can replicate.

This document is the protocol. The scheduler that executes it is an implementation detail. Anyone reading this file can rerun the watch by hand, port it to GitHub Actions with API secrets they control, or replace the executor entirely. The protocol is portable; the executor is swappable.

Nothing in this document commits to metrics, benchmarks, or performance claims. It only defines what to look for, where to look, and how to file findings.

## Executor (current, informational)

- Runtime: Perplexity platform scheduler (subagent).
- Handle: cron id `64822c1c` (visible only through the platform API used to create it).
- Cadence: `0 2 * * 5` UTC = Friday 09:00 Asia/Bangkok, weekly.
- Reason it does not live in `.github/workflows/`: LLM-judgment relevance filter and built-in `search_web` / `search_vertical` access do not have a drop-in GitHub Actions equivalent without paid third-party search API keys (Serper / NewsAPI / SerpAPI), which the repository does not carry as secrets today. Migration path is captured under "Future work" below.

The executor is authoritative for scheduling only. The protocol below is authoritative for behaviour. If they disagree, the protocol wins and the executor gets fixed.

## Targets

Ten competitors, one targeted query per player. Queries prefer product/SKU names over parent company names so brand-level financial noise (M&A, stock moves, unrelated business lines) does not drown out mesh-specific signal.

| Player | Query string | Signal focus |
|---|---|---|
| TERASi RU1 (Sweden) | `TERASi RU1 mm-wave mesh drone` | mm-wave mesh product |
| Elistair (France) | `Elistair tethered drone news` | tethered drone platform |
| AT&T Flying COW | `AT&T Flying COW tethered 5G news` | tethered 5G aerostat |
| Persistent Systems | `Persistent Systems MPU5 Wave Relay MANET` | MPU5 / Wave Relay MANET product |
| Rajant | `Rajant Kinetic Mesh news` | Kinetic Mesh protocol |
| Doodle Labs | `Doodle Labs Mesh Rider news` | Mesh Rider radios |
| Fraunhofer IIS | `Fraunhofer IIS UASFeed Bluetooth FANET` | Bluetooth FANET research |
| Meshmerize + 8devices | `Meshmerize 8devices mesh news` | industrial mesh SDK |
| goTenna | `goTenna Pro X2m mesh news` | Pro X2m tactical mesh |
| World Mobile | `World Mobile stratospheric balloon news` | HAPS / stratospheric |

Recency window on all ten queries: 7 days.

## Academic sweep

`search_vertical` with `vertical=academic`, `recency=month`, one query per keyword string:

- `mesh routing FANET drone`
- `ternary neural network inference edge`
- `silicon-bound DePIN cryptographic anchor`
- `Noise protocol IoT mesh`

Preprint servers (arXiv, IACR, hal.science) are treated as first-party sources.

## Relevance filter

Any single trigger below is sufficient to save a finding. The list is intentionally narrow — the filter's job is to keep the weekly output honest.

Triggers (any one):

1. New product or SKU with a public spec sheet.
2. Public benchmark reporting throughput, range, latency, or power with numeric values (not marketing adjectives).
3. Government or large private contract that names a MANET / mesh / FANET component.
4. Regulatory decision (FCC / ETSI / ITU) touching mesh, FANET, or DePIN spectrum.
5. Preprint or peer-reviewed paper with a direct overlap on the tri-net stack: mesh routing, ternary neural network inference, silicon-bound DePIN anchor, or the Noise protocol on IoT.
6. Funding round Series A or later ($10M+) where the announcement explicitly names mesh, FANET, or DePIN as the product.

Exclusions (drop even if superficially related):

- M&A between IT conglomerates without a mesh-specific product line.
- Share-price movement, earnings coverage, analyst notes.
- General marketing content, LinkedIn posts, corporate blog fluff.
- Social-media discussion (Reddit, X) unless it links to a primary source — in which case the primary source is what gets cited, and the social link is discarded.

## Source discipline

- Every claim in the weekly report cites the URL where the claim can be verified.
- Preferred sources, in order: original press release / spec sheet on the company's own domain, then trade press (`militaryembedded.com`, `defensenews.com`, `unmannedairspace.info`, etc.), then wire coverage (Reuters, Bloomberg). Aggregators (Yahoo, MSN, Moneycontrol) are only used when they carry the wire copy verbatim and no better source exists.
- Reddit, X, Hacker News, and LinkedIn are never cited directly. If a social post is what surfaced the story, chase the linked article and cite that.

## Filing findings

If any finding survives the filter:

1. Create branch `feat/competitor-watch-<YYYY-MM-DD>` off `main` (dated to the run day in Asia/Bangkok).
2. Add `docs/COMPETITOR_WATCH_<YYYY-MM-DD>.md` with one section per surviving finding. Every claim carries an inline markdown link to its source.
3. Push and open a **draft** pull request labelled `documentation,drone-mesh`. Draft, always — the human merges, never the executor.
4. Send one in-app notification with at most three bullets summarising the week plus the PR URL. No push, no email.

If nothing survives:

- Silence. No file, no branch, no PR, no notification. A silent week is a valid outcome and the primary defense against alert fatigue.

## Deduplication

- If a `feat/competitor-watch-<YYYY-MM-DD>` branch already exists dated within the last 7 days AND its PR is still draft (not merged, not closed), append new findings to that PR instead of opening a second one. The date in the filename stays whatever it was on the first push.
- Never rewrite history on a shared branch. Only append.

## Hard rules

- Never merge a competitor-watch PR from the executor. Human merge only.
- Never push to `main` directly.
- Never fabricate metrics. If a benchmark number is not in a citable source, it does not appear in the report.
- Pre-silicon Trinity claims are tagged explicitly wherever they appear.
- Anchor `phi^2 + phi^-2 = 3` present in every generated report.

## Reproducing this watch by hand

Anyone with a terminal and the queries above can run the watch manually and produce the same shape of output. Rough recipe:

```
# 1. Run the ten product queries with a 7-day recency filter on any
#    general-purpose web search API of your choice.
# 2. Run the four academic queries on arXiv (https://arxiv.org/a) with a
#    1-month window.
# 3. Apply the relevance filter above. Drop anything not on the trigger list.
# 4. Chase every surviving hit to its primary source and record the URL.
# 5. If at least one survives, open a draft PR against gHashTag/tri-net on
#    a feat/competitor-watch-<YYYY-MM-DD> branch with docs/COMPETITOR_WATCH_
#    <YYYY-MM-DD>.md and the label pair documentation,drone-mesh.
```

The executor automates steps 1-5. The protocol above is what the executor is executing.

## Future work

- **In-repo executor (GitHub Actions).** Replace or shadow the platform cron with `.github/workflows/competitor-watch.yml` on the same `0 2 * * 5` schedule. Prerequisites: repository secrets for a web-search API (Serper, SerpAPI, or NewsAPI) plus arXiv access (free, no key). Relevance filter becomes deterministic keyword scoring rather than LLM judgment — narrower, higher-precision, less recall. Track as a separate PR with the secrets checklist called out.
- **Reproducibility fixture.** A recorded set of past weekly outputs (`docs/competitor-watch/archive/`) so third parties can replay the filter against the same input corpus and compare their result to ours. Only becomes meaningful once a few weeks have run.

## Change log

- 2026-07-04 — initial spec. Executor: platform cron `64822c1c`.
