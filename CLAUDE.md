# Ralph Deluxe — Project Conventions

## Overview
Ralph Deluxe is a bash orchestrator that drives Claude Code CLI through structured task plans. Each coding iteration writes a freeform handoff narrative that becomes the primary context for the next iteration. The orchestrator supports two modes: `handoff-only` (default) and `handoff-plus-index` (adds a periodic knowledge indexer). It includes git-backed rollback, validation gates, telemetry, and an operator dashboard.

## Directory Structure
- `.ralph/ralph.sh` — Main orchestrator script
- `.ralph/lib/` — Helper modules (cli-ops.sh, context.sh, validation.sh, git-ops.sh, plan-ops.sh, compaction.sh, telemetry.sh)
- `.ralph/config/` — JSON configs and schemas (ralph.conf, handoff-schema.json, mcp-*.json)
- `.ralph/templates/` — Prompt templates (coding-prompt.md, memory-prompt.md, knowledge-index-prompt.md, first-iteration.md)
- `.ralph/skills/` — Per-task skill injection files (markdown)
- `.ralph/handoffs/` — Raw handoff JSON from each iteration
- `.ralph/context/` — Legacy compacted context files
- `.ralph/control/` — Dashboard-to-orchestrator command queue (commands.json)
- `.ralph/logs/` — Orchestrator logs (ralph.log, events.jsonl, amendments.log, validation/)
- `.ralph/dashboard.html` — Single-file operator dashboard
- `.ralph/serve.py` — HTTP server for dashboard (static files + control plane POST endpoints)
- `.ralph/knowledge-index.md` — Categorized knowledge index (handoff-plus-index mode)
- `.ralph/knowledge-index.json` — Iteration-keyed index for dashboard (handoff-plus-index mode)
- `plan.json` — Task plan (project root for visibility)
- `tests/` — bats-core test suite

## Operating Modes
- `handoff-only` (default): The freeform handoff narrative IS the memory. No compaction or indexing runs
- `handoff-plus-index`: Handoff narrative + periodic knowledge indexer that maintains categorized `.ralph/knowledge-index.md` and `.ralph/knowledge-index.json`
- Mode set via `--mode` CLI flag, `RALPH_MODE` in ralph.conf, or dashboard settings panel
- Priority: CLI flag > config file > default (`handoff-only`)

## Handoff Schema
- `summary` (string, required) — One-line description of what was accomplished
- `freeform` (string, required) — Full narrative briefing for the next iteration (the most important field)
- Plus structured fields: task_completed, deviations, bugs_encountered, architectural_notes, constraints_discovered, files_touched, plan_amendments, tests_added

## Telemetry
- Events logged to `.ralph/logs/events.jsonl` as JSONL (`{timestamp, event, message, metadata}`)
- Event types: orchestrator_start/end, iteration_start/end, validation_pass/fail, pause, resume, note, skip_task
- All `emit_event` calls in ralph.sh are guarded with `declare -f` checks for graceful degradation
- Control commands use queue-based format in `.ralph/control/commands.json`: `{"pending": [...]}`

## Dashboard
- Single-file HTML at `.ralph/dashboard.html` (vanilla JS + Tailwind CDN)
- Serve via `python3 .ralph/serve.py --port 8080` from project root
- Polls state.json, plan.json, handoffs, events.jsonl, knowledge-index.json every 3 seconds
- Control plane: pause/resume, inject notes, skip tasks, settings — all POST to serve.py

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
- Always use `// "default"` for optional jq fields to avoid empty output

## Testing
- Test framework: bats-core
- Test files: `tests/<module>.bats` (context.bats, compaction.bats, telemetry.bats, integration.bats, etc.)
- Each module has its own test file
- Use `setup()` and `teardown()` for test fixtures
- Test in temporary directories to avoid polluting the project

## Git
- Commits use the format: `ralph[N]: TASK-ID — description`
- Every successful iteration creates a commit
- Failed iterations roll back to the checkpoint
