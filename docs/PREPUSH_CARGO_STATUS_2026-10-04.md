# Preserve Cargo failure before push

Issue #398 addresses the local hook part of #58 finding N11. The old hook piped
`cargo build --release` into `tail` and checked the pipeline's exit status. That
status belonged to `tail`, so an actual compilation failure could pass pre-push.

The hook now checks Cargo directly. Its output remains visible, and a failed
build rejects the push. No other hook, required CI job, compiler pin, warning
baseline, or execution floor changes.

Verification used actual Rust 1.96.0 Cargo compilation and the actual Lefthook
`cargo-build` job in an independent fixture, with no hook exclusions:

| Fixture | Cargo exit | Hook exit | Result |
| --- | ---: | ---: | --- |
| Invalid Rust, old hook | 101 | 0 | Incorrect success reproduced |
| Invalid Rust, fixed hook | 101 | 1 | Push rejected |
| Valid Rust, fixed hook | 0 | 0 | Push allowed |

The fixture references a genuine existing canonical commit; no synthetic commit
was created for the test. The failed build contains a real unresolved function,
not a mocked Cargo command. Source and generated runtime behavior are unchanged.

This narrow hook fix does not close the crypto, discovery, or documentation
tracks in #58 and makes no hardware or deployment claim.
