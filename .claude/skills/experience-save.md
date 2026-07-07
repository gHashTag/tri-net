---
description: Save learning and experience to persistent memory
parameters:
  - name: ring
    type: string
    description: Ring number for context
  - name: phase
    type: string
    description: Phase where learning occurred
  - name: insight
    type: string
    description: The learning or insight to save
---

# Experience Save Skill

Captures learnings from ring work for future reference and agent improvement.

## What to Save

- Debugging insights and solutions
- Pattern discoveries
- Optimization techniques
- L3/L5/L6 law clarifications
- Anti-patterns to avoid

## Storage Location

Learnings are saved to:
- `.trinity/experience.md` - General learnings
- `.trinity/ring-{NNN}.md` - Ring-specific learnings

## Format

```markdown
## Ring {NNN} - {Phase}

**Date:** YYYY-MM-DD
**Issue:** #{number}

### Insight
[The learning or insight]

### Pattern
[Any discovered pattern or approach]

### Anti-pattern
[Anything to avoid]
```

## Access

Saved learnings are:
- Automatically loaded in subsequent sessions
- Used for pattern matching via semantic search
- Incorporated into agent decision-making

## Usage

Call this skill when:
- Completing the "Learn" phase of PHI LOOP
- Discovering a useful pattern during implementation
- Solving a non-trivial bug
- Finding a better approach than initially planned
