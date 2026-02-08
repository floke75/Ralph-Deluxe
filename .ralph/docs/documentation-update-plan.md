# Documentation Update Plan

Structured playbook for applying LLM-optimized documentation across the Ralph Deluxe codebase. Designed to be re-run whenever new files are added or existing documentation drifts.

## Pattern Reference

All documentation follows the standards defined in `CLAUDE.md > Documentation Standards for LLM Agents`. The detailed pattern library lives in the agent memory at `llm-doc-patterns.md`. In brief:

- **Module headers**: PURPOSE → DEPENDENCIES → DATA FLOW → INVARIANTS
- **Function markers**: CALLER, SIDE EFFECT, CRITICAL, INVARIANT, WHY
- **Anti-patterns**: No restating code, no commenting obvious logic, no filler prose

## File Inventory and Update Checklist

### Parallelization Key

- **Group**: Files in the same group can be updated in parallel (no cross-dependencies during documentation)
- **Order**: Groups must be processed in sequence (later groups reference patterns established by earlier ones)

### Group 1 — Foundation (run in parallel)

Smallest files with fewest cross-references. Use these to establish and validate the pattern template before scaling.

| File | Lines | Module Header | Function Comments | Status |
|------|-------|:---:|:---:|:---:|
| `.ralph/lib/git-ops.sh` | ~65 | Required | Required | Done |
| `.ralph/lib/telemetry.sh` | ~175 | Required | Required | Done |

**Gate**: Review Group 1 output for pattern consistency before proceeding.

### Group 2 — Mid-Complexity (run in parallel)

Independent modules with moderate cross-references.

| File | Lines | Module Header | Function Comments | Status |
|------|-------|:---:|:---:|:---:|
| `.ralph/lib/cli-ops.sh` | ~170 | Required | Required | Done |
| `.ralph/lib/validation.sh` | ~188 | Required | Required | Done |
| `.ralph/lib/plan-ops.sh` | ~225 | Required | Required | Done |
| `.ralph/lib/progress-log.sh` | ~329 | Required | Required | Done |

### Group 3 — High-Complexity (run sequentially)

These modules have deep cross-references and must be reviewed in order. context.sh defines the prompt assembly contract that compaction.sh depends on.

| File | Lines | Module Header | Function Comments | Status |
|------|-------|:---:|:---:|:---:|
| `.ralph/lib/context.sh` | ~644 | Required | Required | Done |
| `.ralph/lib/compaction.sh` | ~597 | Required | Required | Done |

### Group 4 — Orchestrator and Non-Bash (run in parallel)

| File | Lines | Module Header | Function Comments | Status |
|------|-------|:---:|:---:|:---:|
| `.ralph/ralph.sh` | ~914 | Required | Required | Done |
| `.ralph/serve.py` | ~239 | Required (Python docstring) | Required | Done |

### Group 5 — Project-Level Documentation

| File | Purpose | Status |
|------|---------|:---:|
| `CLAUDE.md` | Architecture overview, conventions, doc standards | Done |
| `.ralph/docs/documentation-update-plan.md` | This file | Done |

### Group 6 — Templates and Config (documentation-light)

Templates and config files need only a brief header comment explaining their purpose and who consumes them. No function-level documentation needed.

| File | Header Comment | Status |
|------|:---:|:---:|
| `.ralph/templates/coding-prompt.md` | Required | Pending |
| `.ralph/templates/knowledge-index-prompt.md` | Required | Pending |
| `.ralph/templates/knowledge-index-system.md` | Required | Pending |
| `.ralph/config/ralph.conf` | Required | Pending |
| `.ralph/config/handoff-schema.json` | N/A (JSON) | Skip |
| `.ralph/config/mcp-coding.json` | N/A (JSON) | Skip |
| `.ralph/config/mcp-memory.json` | N/A (JSON) | Skip |
| `.ralph/dashboard.html` | Required (HTML comment) | Pending |

### Group 7 — Test Files (documentation-light)

Test files need only a file-level comment explaining what module they test and any non-obvious test setup patterns. Individual test functions are self-documenting via their bats `@test` descriptions.

| File | Header Comment | Status |
|------|:---:|:---:|
| `tests/context.bats` | Required | Pending |
| `tests/compaction.bats` | Required | Pending |
| `tests/plan-ops.bats` | Required | Pending |
| `tests/validation.bats` | Required | Pending |
| `tests/integration.bats` | Required | Pending |
| `tests/cli-ops.bats` | Required | Pending |
| `tests/git-ops.bats` | Required | Pending |
| `tests/telemetry.bats` | Required | Pending |
| `tests/progress-log.bats` | Required | Pending |
| `tests/ralph.bats` | Required | Pending |

## Handling New Files

When new `.sh`, `.py`, or other source files are added to the project, apply this checklist:

### Discovery Command

```bash
# Find source files added since the last documentation pass
# Compare against this plan's file inventory
comm -23 \
  <(find .ralph -name '*.sh' -o -name '*.py' | sort) \
  <(grep -oP '`[^`]*\.(sh|py)`' .ralph/docs/documentation-update-plan.md | tr -d '`' | sort)
```

### New File Checklist

1. **Determine documentation tier**:
   - Library module (`.ralph/lib/*.sh`) → Full treatment: module header + function comments
   - Template/config → Header comment only
   - Test file → Header comment + non-obvious setup documentation only
2. **Add module header** following the template in `CLAUDE.md > Documentation Standards`
3. **Add function markers** (CALLER, SIDE EFFECT, CRITICAL, INVARIANT, WHY) where applicable
4. **Cross-reference** callers and callees in existing documented modules
5. **Update this plan** — add the new file to the appropriate group table
6. **Update CLAUDE.md** if the new file introduces a new module to the dependency map
7. **Run tests** — documentation changes must not break any of the 251+ bats tests

## Execution Best Practices

### Parallelization Strategy

```
Phase 1: Groups 1-2 (6 files, all parallel)
  ↓ gate: pattern review
Phase 2: Group 3 (2 files, sequential — context.sh before compaction.sh)
  ↓ gate: cross-reference review
Phase 3: Groups 4-5 (4 files, all parallel)
  ↓ gate: full test suite
Phase 4: Groups 6-7 (14 files, all parallel — lightweight headers only)
  ↓ gate: final test suite
```

### Quality Gates

| Gate | When | Check |
|------|------|-------|
| Pattern validation | After Group 1 | Module header has all 4 sections, function markers are consistent |
| Cross-reference audit | After Group 3 | Every CALLER/SIDE EFFECT references a real function/file |
| Test regression | After Groups 3, 4 | All bats tests pass (`bats tests/`) |
| Final audit | After all groups | Run discovery command — no undocumented source files remain |

### Common Pitfalls

1. **Over-commenting obvious code** — If the LLM can infer it from the code, don't comment it. Every redundant comment burns context tokens.
2. **Stale cross-references** — When renaming a function, grep for its name in all module headers and CALLER annotations.
3. **Breaking awk parsers** — Section headers in context.sh are parsed by awk. Changing `## Current Task` to `## Task` breaks truncation. Always check downstream parsers.
4. **Forgetting the test run** — Documentation edits can break things: accidental character insertion in code, unclosed comments, shifted line numbers in tests that use line-count assertions.
5. **Documenting config defaults in two places** — The single source of truth for defaults is `CLAUDE.md > Configuration`. Module headers should reference the table, not duplicate values.

### Token Budget Awareness

CLAUDE.md is loaded into every LLM system prompt. Keep it under 200 lines of dense content. When adding new sections:
- Can an existing table absorb the information? (Prefer combined tables)
- Is this reference material that belongs in a separate doc? (Link from CLAUDE.md, don't inline)
- Does every sentence add information the LLM cannot get from code? (Delete if no)

## Maintenance Schedule

- **On every PR that adds/modifies `.ralph/lib/*.sh`**: Check that module header and function comments are current
- **On every PR that adds new modules**: Run the discovery command, update this plan
- **Quarterly**: Full audit — re-run discovery, check cross-references, verify test coverage of documented invariants
