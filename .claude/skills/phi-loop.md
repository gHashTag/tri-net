---
description: PHI LOOP execution - guides AI through 9 phases of ring-based development
parameters:
  - name: ring
    type: string
    description: Ring number (e.g., "072")
  - name: phase
    type: string
    description: Target phase (issue, spec, tdd, impl, gen, seal, verify, land, learn)
  - name: context
    type: string
    description: Optional context about the work
---

# PHI LOOP Skill

The PHI LOOP is a 9-phase development methodology for t27 rings.

## Phases

1. **Issue** - Define problem or requirement
2. **Spec** - Write .t27 specification
3. **TDD** - Write tests in spec before implementation
4. **Code/Impl** - Implement according to spec
5. **Gen** - Run `tri gen` to generate code from spec
6. **Seal** - Verify generated code and seal hash
7. **Verify** - Run `tri test` or conformance checks
8. **Land** - Merge changes to main branch
9. **Learn** - Capture learnings and update knowledge base

## Usage

When this skill is invoked:

1. Determine current phase from branch name (ring-NNN-PHASE)
2. Execute the appropriate phase actions
3. Provide clear output when phase is complete
4. Suggest next phase with explicit "→ Phase {N}" notation

## Output Format

On phase completion, include:
```
Phase complete: [phase name]
→ Phase [next phase number]: [next phase name]
```

This triggers automatic branch creation for next phase.
