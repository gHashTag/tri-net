# Explicit generation and staged verification

Issue #101 exposed a conflicting workflow: `cargo build` could rewrite tracked
generated files when a sibling compiler was present, while `no-gen-edits`
rejected every generated change. Ordinary builds now consume committed output.
Generation is an explicit action, and the hook verifies its result.

## Build an existing checkout

```sh
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
cargo build --release
cargo test
```

These commands do not regenerate artifacts or need a sibling t27 checkout.
They cover declared Cargo targets; the missing `tri_rti` target remains excluded.

## Change a specification

Use the compiler revision pinned by `spec-drift-guard.yml`:
`eb8b4208168557b36dca3a771f6901a5b10d9ef0`. Build its `t27c` binary separately
and set `T27C` to its absolute path. A newer compiler is not an equivalent drift
oracle; changing the pin requires a separately reviewed backend sweep.

For example, after editing `specs/wire.t27`:

```sh
export T27C=/absolute/path/to/pinned/t27c
"$T27C" parse specs/wire.t27 > /dev/null
"$T27C" typecheck specs/wire.t27
"$T27C" gen-rust specs/wire.t27 > gen/rust/wire.rs
"$T27C" gen specs/wire.t27 > gen/zig/wire.zig
"$T27C" gen-c specs/wire.t27 > gen/c/wire.c
cargo fmt --all
git add specs/wire.t27 gen/rust/wire.rs gen/zig/wire.zig gen/c/wire.c
cargo run --bin trinet-regen -- --check-staged
```

Check each generation command's exit status before proceeding. Regenerate every
existing backend for the changed spec; some specs do not have all three outputs.
Run the spec's generated tests and the repository checks before committing.

The existing all-Rust generator is also available explicitly:

```sh
T27C=/absolute/path/to/pinned/t27c cargo run --bin trinet-regen
```

It parses every source spec and regenerates Rust only. It stops on errors; files
generated before an error may already have changed. Review the complete diff.
Use the Cargo command instead of the old tracked platform-specific `tools/regen`
executable. That legacy executable is not replaced by this change.

## What the staged check proves

For each added or modified `gen/{rust,zig,c}/NAME.EXT`, the checker reads both
`specs/NAME.t27` and the artifact from the Git index. It generates into temporary
storage with the selected compiler and compares the result. Rust is normalized
with rustfmt on both sides, matching CI; C and Zig compare byte-for-byte.

Unstaged changes cannot approve a different source or artifact in the index.
Missing indexed source, missing or failing compiler, empty compiler output,
formatter failure, unsupported output paths, and mismatches fail the check.
Without staged generated files the check succeeds without a compiler.

The Lefthook command compiles the checker with standalone `rustc`, so unrelated
unstaged library errors do not prevent verification. The command does not write
source files, generated files, or the index. It does not replace typechecking,
tests, or the required full-corpus CI drift check.

## Verification for this change

- A full-project fixture with the old build script and the pinned compiler
  reproduced an automatic rewrite of a controlled generated-file marker.
- The same build after removing the script retained the marker and all 284
  generated-file hashes, with the compiler still installed.
- Seventeen real Git-index and hook controls passed, including all three backends,
  manual corruption, formatting normalization, differing index/worktree inputs,
  missing tools/source, command failure, and empty compiler output.
- Explicit generation produced byte-identical pinned Rust output.
- CI additionally runs the checker against an independent indexed spec and
  rejects backend corruption and differing staged source.

This is host tooling evidence. It makes no claim about radio hardware, deployment,
or complete model inference.
