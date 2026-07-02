# Autonomous improvement loop — protocol

This repo is improved continuously by an autonomous agent (an in-session **loop**
and a scheduled **cron**). Both run the identical iteration below. One focused,
tested improvement per run; **PRs only — never push straight to `main`**.

## One iteration

1. **Auth & sync.** Use `GH_TOKEN` from the environment, or read a token from
   `~/.config/trios-mesh/gh_token` (gitignored, kept off the repo). Then
   `git -C /Users/ssdm4/Desktop/PROJECTS/CLAUDE/trios-mesh pull --ff-only`.
2. **Read the backlog.** `docs/STRENGTHEN.md` (science-driven backlog) +
   `gh issue list -R gHashTag/trios-mesh --label research --state open`.
3. **Pick one item** — highest priority, open, unblocked, `auto`-implementable
   (software: routing, crypto, PHY host-model, GF16/ternary Rust model, FEC,
   tests). Skip hardware/RTL/procurement/regulatory items (they need a human).
   Skip anything already having an open PR/branch.
4. **Implement** on a branch `feat/<slug>`. Keep it surgical; cite the paper
   (arXiv/doi or our repo) in a code comment and the commit body. Add/extend
   tests. Keep `#![forbid(unsafe_code)]`.
5. **Gate.** Run `scripts/verify.sh` (`fmt --check` + `clippy -D warnings` +
   `test`). **If it fails, fix or abort — do NOT push broken code.**
6. **PR.** Commit (with `Co-Authored-By`), push, `gh pr create` with `Closes #N`.
   **Do not auto-merge** — leave it for human review.
7. **Log.** Append one line to `docs/ITERATION_LOG.md` (date · item · PR · result)
   and comment on the issue.
8. **Backlog empty?** Do a short research pass (WebSearch 1–2 papers on
   FANET/PHY/anti-jam), then file ONE new `research`-labelled backlog issue
   instead of coding — keep the queue fed.

## Guardrails
- One improvement per run. Small diffs. Tests always green before pushing.
- PRs only; a human merges. Never touch hardware or flash boards.
- Never commit secrets. The token lives in env or `~/.config/trios-mesh/gh_token`.
- Prefer items with a real citation; reject any that need fabricated evidence.

## Backlog source of truth
`docs/STRENGTHEN.md` + open `research`-labelled issues. Priority 1 = highest.
