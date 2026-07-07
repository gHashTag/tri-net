---
name: t27-fpga-spec
description: Author a synthesizable .t27 FPGA spec (module/const/fn + test/invariant) and get iverilog-clean, simulatable Verilog from t27c gen-verilog. Use when writing or debugging specs/fpga/*.t27, understanding the gen-verilog backend, or porting hardware logic (e.g. a DSP datapath) into the T27 spec-first language.
---

# Authoring synthesizable .t27 FPGA specs (gen-verilog)

`.t27` -> Verilog/C/Rust/Zig via `t27c` (binary at `./target/release/t27c`, build `cargo build --release -p t27c`). Call the binary DIRECTLY (`./scripts/tri` passes `--repo-root`, which the binary rejects). Commands: `parse`, `typecheck`, `gen-verilog <f>` (stdout), `seal <f> --save`, `suite --repo-root .`. Comments `//`. **L3: ASCII-only, English identifiers. L4: every spec needs >=1 `test`/`invariant`/`bench`.**

## Language cheat-sheet (verified)
```
module Name {
    use base::types;
    const K : u16 = 0x1FFF;          // scalar consts only; type annotation required
    const N : usize = 13;            // 0x/0b/decimal/underscores ok (now emit decimal)
    var st_field : u8 = 0;           // top-level scalar vars -> reg + initial
    fn f(p: u16) -> i32 {            // -> void = a task; else a function
        if (c) { return A; } else { return B; }   // if/ELSE with a single assignment per path
        // while (i < N) { ...; i = i + 1; }
        return e;
    }
    test my_name                     // indentation-scoped, NO braces
        given x = f(5)
        then x == 13
    invariant inv
        assert K == 8191
}
```
Types: bool, u8/i8..u64/i64, usize (i* are signed). Ops `+ - * / % << >> & | ^ ~`, keywords `and`/`or`/`!` (NOT `&&`). `expr as T` casts. `for`/`while`/`match` exist.

## Do / Don't (backend reality)
- **Module interface is ALWAYS the fixed `(clk, rst_n, en, ready)`** — no data ports. All datapath I/O lives in `const`/`var`/`fn`; correctness is proven by `test`/`invariant` blocks, which are EMITTED into the Verilog and RUN in simulation (`vvp`).
- **DON'T declare array-const tables** (`const T : [N]u8 = [...]`) — arrays don't lower; they abort or stub to `0 /* TODO */`. Pack small tables into a scalar (e.g. a 13-bit Barker sequence as one `u16`, extract with `>>`/`&`).
- Use if/**else** single-assignment (not fall-through `return`), flat function bodies, named begin blocks — these were 2026-07 backend gaps, now fixed on master (PR #1250) but stay idiomatic.
- Prefer top-level scalar `var`s over struct fields for state.

## Validation workflow (the proof)
```
t27c parse f.t27 && t27c typecheck f.t27
t27c gen-verilog f.t27 > /tmp/f.v          # inspect: all fns present, no TODO
iverilog -t null /tmp/f.v                   # must be 0 errors
# simulate: the embedded `test` blocks run as assertions
iverilog -o /tmp/sim /tmp/f.v tb.v && vvp /tmp/sim   # look for PASSED / FAILED
t27c seal f.t27 --save                      # required (seal = <dir>_<Module>.json)
t27c suite --repo-root .                     # CI-equivalent: parse/typecheck/gen x4/seal-verify
```
A tiny hierarchical testbench can call module functions: `dut.correlate(16'd5535)`.

## Hard-won gotchas
- **Diagnose empirically.** "const/var run dropped" looked like a codegen bug but was the PARSER (stray `;`); found it by dumping the parse AST (`t27c parse`), not by guessing.
- **Seal filename = `<dir>_<Module>.json`** -> two specs with the same module name COLLIDE and can never both seal-verify -> give each a unique module name.
- Any backend change drifts every spec's gen-hash -> run a **reseal-sweep** (`for f in $(find specs compiler -name '*.t27'); do t27c seal "$f" --save; done`) before the suite is green again.
- **Don't chase iverilog-cleanliness of non-datapath specs** (config/ISA/protocol models using strings/`match`/arrays-of-structs) — forcing RTL there is meaningless. Only genuine datapaths (a modem, uart, mac, and fifo/memory once array-RAM lowering exists) are worth making synthesizable.

## Commit gates (t27 repo)
`docs/NOW.md` "Last updated:" must == today (add a `## slug (Closes #N)` entry); pre-push needs a notebook id -> `SKIP_NOTEBOOK_GATE=1 git push`; L1 needs `Closes #N`. Default branch `master`; **branch `codegen-clean` is stale (1069 behind a rebased master) — work off master.** Fetch is slow/hangs: `git fetch "https://x-access-token:$TOKEN@github.com/gHashTag/t27.git" "+master:refs/remotes/origin/master"`; never run parallel fetches (they deadlock the `.git` lock). Use `git worktree` to build/PR without disturbing the checked-out branch.

**Anchor:** phi^2 + phi^-2 = 3
