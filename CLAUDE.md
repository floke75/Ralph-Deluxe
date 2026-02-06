# Ralph Deluxe — Project Conventions

## Overview
Ralph Deluxe is a bash orchestrator that drives Claude Code CLI through structured task plans. It alternates between coding iterations and memory-compaction iterations, with git-backed rollback, validation gates, and hierarchical context management.

## Directory Structure
- `.ralph/ralph.sh` — Main orchestrator script
- `.ralph/lib/` — Helper modules (context.sh, validation.sh, git-ops.sh, plan-ops.sh, compaction.sh)
- `.ralph/config/` — JSON configs and schemas
- `.ralph/templates/` — Prompt templates (markdown)
- `.ralph/skills/` — Per-task skill injection files (markdown)
- `.ralph/handoffs/` — Raw handoff JSON from each iteration
- `.ralph/context/` — Compacted context files
- `.ralph/logs/` — Orchestrator logs
- `plan.json` — Task plan (project root for visibility)
- `tests/` — bats-core test suite

## Bash Conventions
- All scripts use `#!/usr/bin/env bash` and `set -euo pipefail`
- Functions return 0 on success, non-zero on failure
- All functions log via the shared `log()` function defined in ralph.sh
- Variable names use UPPER_SNAKE_CASE for constants/config, lower_snake_case for locals
- Quote all variable expansions: `"$var"` not `$var`
- Use `[[ ]]` for conditionals, not `[ ]`
- Each library module is sourced by ralph.sh and can be tested independently

## JSON Conventions
- All JSON processing uses `jq`
- Prefer simple, composable jq filters over complex one-liners
- Test every jq expression in isolation before integrating
- All config files must validate with `jq . < file.json`

## Testing
- Test framework: bats-core
- Test files: `tests/<module>.bats`
- Each module has its own test file
- Use `setup()` and `teardown()` for test fixtures
- Test in temporary directories to avoid polluting the project

## Git
- Commits use the format: `ralph[N]: TASK-ID — description`
- Every successful iteration creates a commit
- Failed iterations roll back to the checkpoint
