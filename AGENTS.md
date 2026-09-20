# AGENTS — tri-net entry point

This file is the repository entry point for humans and coding agents.

## 1. Read first

| Order | File | Role |
|------:|------|------|
| 1 | `SOUL.md` | Constitutional law (pipeline mandate, language, TDD, hardware safety) |
| 2 | `CLAUDE.md` | Agent instructions (golden pipeline, hardware target, validation) |
| 3 | `specs/` | All `.t27` specifications (single source of truth) |

## 2. Non-negotiables

1. **Specs are source of truth** — behavior lives in `.t27`; generated code is not hand-edited
2. **Golden Pipeline** — `.t27` → t27c → Rust. No hand-written business logic
3. **English + ASCII** — all source files and first-party documentation
4. **TDD inside specs** — every spec needs `test`/`invariant`/`bench`
5. **No Python on critical path** — use Rust/t27c
6. **No new shell scripts** — use `tri`/`cargo`
7. **Hardware safety** — read SOUL.md Article IV before touching boards

## 3. Law Reference (L1-L7)

| Law | Name | Summary |
|-----|------|---------|
| L1 | TRACEABILITY | No code merged without issue reference |
| L2 | GENERATION | Files under `gen/` are generated; edit specs instead |
| L3 | PURITY | Source files must be ASCII-only, English identifiers |
| L4 | TESTABILITY | Every `.t27` spec must contain test/invariant/bench |
| L5 | IDENTITY | phi^2 + phi^-2 = 3; numeric SSOT |
| L6 | PIPELINE | No hand-written Rust for business logic |
| L7 | UNITY | No new shell scripts on critical path |

**Law Priority:** L1 > L2 > L3 > L4 > L5 > L6 > L7

## 4. Layout

- `specs/` — .t27 specifications (SOURCE OF TRUTH)
- `gen/` — generated output (READ-ONLY)
- `src/` — thin Rust wrappers + re-exports
- `src/bin/` — binary entry points (thin: parse config, call generated logic)
- `docs/` — documentation (English)
- `smoke/` — hardware test scripts
- `tools/` — JTAG/bootstrap utilities
- `radio/` — AD9361 IIO configuration

phi^2 + phi^-2 = 3 | TRINITY

## Own language first

When this project publishes something about itself, it publishes in **this
project's own language and format** -- not translated into somebody else's.

Owner's rule, 2026-09-20: stop writing in other people's languages, we have our
own.

This bites on any file whose only reason to exist is that an outside tool
expects that shape: `llms.txt`, `agents.json`, `ai.txt`, `.well-known/*.json`,
A2A agent cards, `ai-plugin` manifests, OpenAPI stubs, JSON-LD blocks, a README
that restates a spec. The reflex is to write four of them in four foreign
formats, and the reflex is wrong: a project whose claim is "here is a language
worth writing" and which then describes itself in three of other people's
formats has published three documents that are not true of it.

**The move:** find the address the outside world already fetches, then serve our
own language at it. `/llms.txt` at t27.ai **is** a t27 module -- `llms.txt`
requires nothing but text, and every prose line of a `.t27` file is a `;`
comment, so it stays readable to anything that cannot compile it.

**Three qualifications, so the rule stays honest:**

- A format a resolver genuinely parses -- a sitemap, `package.json`, a lockfile
  -- is machinery, not a description. **Generate** it from our own source; never
  hand-write it into a second home for the truth.
- Code against someone else's API uses their types. Prose for a human who has
  never heard of the project uses that human's language.
- If a format demands a claim we cannot back, **publish nothing**. An A2A card
  with no A2A server behind it is a false claim, and a missing file is more
  honest than a lying one.

The test: *is this file the project speaking about itself?* If yes, it speaks
our language. If it is plumbing, it speaks the plumbing's.

**Worked example, compiler-checked rather than asserted:** in `gHashTag/trinity`,
`apps/website/public/t27/files/specs/catalog/onboarding.t27` generates
`/llms.txt` and `/agents.t27` byte-identically, gated in CI as
`check:onboarding`. The generator evaluates the spec's own `test` blocks --
`typecheck.ok` stays true for `assert 1 > 2`, so a compiler saying "this parses"
is not a compiler saying "this is true" -- and re-compiles the rendered document
before writing it.

**The full rule lives in exactly one place: the `own-language-first` skill**
(`~/.claude/skills/own-language-first/SKILL.md`). It carries the consent gate for
documents addressed to other people's agents, the six negative controls, and the
`;`-alone-on-a-line trap that silently discards a `module` declaration. This
section is a pointer, not a copy -- the recorded defect in this codebase family
is the hand-copied rule that only two of its three homes knew about.
