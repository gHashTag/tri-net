## Pipeline Compliance Checklist

- [ ] All business logic defined in `.t27` spec (not hand-written in `.rs`)
- [ ] Spec has `test` or `invariant` blocks
- [ ] `t27c parse <spec>` returns 0
- [ ] `cargo build --release` compiles
- [ ] No hand-edits to `gen/` directory
- [ ] English + ASCII only in source files
- [ ] Issue referenced (`Closes #N`)

## What changed
<!-- Brief description -->

## Spec → Code mapping
<!-- Which .t27 spec generated which Rust code -->

phi^2 + phi^-2 = 3
