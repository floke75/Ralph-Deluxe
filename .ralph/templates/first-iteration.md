<!-- Purpose: startup guidance for iteration-1 runs with no prior handoff context. -->
<!-- Consumed by: iteration prompt assembly in orchestrator startup flow, when current iteration equals 1. -->

# First Iteration — Self-Improvement Run

This is **iteration 1** of Ralph Deluxe running on itself in agent-orchestrated mode.

## Project Context
- Ralph Deluxe is a bash orchestrator that drives Claude Code CLI through structured task plans
- The project is fully built with 314 bats tests and shellcheck coverage
- All code: `.ralph/ralph.sh` (main, ~580 lines) and `.ralph/lib/*.sh` (9 modules)
- Tests: `tests/*.bats` (8 files)
- Config: `.ralph/config/ralph.conf`

## Current Issues (TASK-101)

There are **7 failing bats tests** and **3 shellcheck SC2034 warnings** that must be fixed:

### Shellcheck Warnings (SC2034 — unused variables)
- `agents.sh:169`: `task_title` assigned but never used in `build_context_prep_input()`
- `context.sh:234`: `trim_by` declared but never used in `truncate_to_budget()`
- `context.sh:256`: `over` assigned but never used in `truncate_to_budget()`

### Failing Tests
- **context.bats tests 127, 128, 168, 172**: `truncate_to_budget` section parsing and trimming behavior — the function uses awk to match `## <Name>` section headers and trim by priority. Read the tests to understand expected behavior, then fix the function or tests as appropriate.
- **compaction.bats tests 111, 113**: `verify_knowledge_index` schema validation — test 111 expects valid modern schema to pass, test 113 expects unknown supersedes targets to be rejected.
- **validation.bats test 314**: `run_validation` with empty `RALPH_VALIDATION_COMMANDS` array — `set -u` causes "unbound variable" on `${RALPH_VALIDATION_COMMANDS[@]}`. Need to guard the array access.

## Key Conventions
- `CLAUDE.md` contains auto-generated project conventions (loaded automatically via `-p` flag)
- Every `.sh` file uses `set -euo pipefail`
- macOS ships bash 3.2 — no `${var^^}` (bash 4+), no `declare -A` with `set -u`
- Functions return 0/non-zero, log via shared `log()`
- Test with bats-core in `tests/` directory

## Handoff Importance
Your handoff is the **only context** the next iteration receives. Document thoroughly:
- What you fixed and why the fix works
- Which files you modified
- Any patterns you noticed
- Remaining risks for subsequent tasks

The handoff JSON must match the schema provided via `--json-schema`.
