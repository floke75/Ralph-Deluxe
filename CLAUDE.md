# Ralph Deluxe — Project Conventions

## Overview
Ralph Deluxe is a bash orchestrator that drives Claude Code CLI through structured task plans. Each coding iteration writes a freeform handoff narrative that becomes the primary context for the next iteration. The orchestrator supports two modes: `handoff-only` (default) and `handoff-plus-index` (adds a periodic knowledge indexer). It includes git-backed rollback, validation gates, telemetry, and an operator dashboard.

## Directory Structure
- `.ralph/ralph.sh` — Main orchestrator script
- `.ralph/lib/` — Helper modules (cli-ops.sh, context.sh, validation.sh, git-ops.sh, plan-ops.sh, compaction.sh, telemetry.sh, progress-log.sh)
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
- `.ralph/progress-log.md` — Auto-generated progress log (human/LLM-readable)
- `.ralph/progress-log.json` — Auto-generated progress log (dashboard-readable)
- `.ralph/state.json` — Orchestrator runtime state (current iteration, mode, compaction counters)
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
- Plus structured fields: task_completed, deviations, bugs_encountered, architectural_notes, constraints_discovered, files_touched, plan_amendments, tests_added, unfinished_business, recommendations

## Context Engineering (context.sh)

### Prompt Structure — `build_coding_prompt_v2()`
Assembles 8 sections in this exact order. Section headers are `## <Name>` and must match exactly for truncation to work.

| # | Section | Source | Present When |
|---|---------|--------|--------------|
| 1 | `## Current Task` | task JSON from plan.json | Always |
| 2 | `## Failure Context` | previous validation output | Retry iterations only |
| 3 | `## Retrieved Memory` | latest handoff: constraints + decisions; in h+i mode also pointer to knowledge-index.md | Always (content varies by mode) |
| 4 | `## Previous Handoff` | `get_prev_handoff_for_mode()` — freeform-only in `handoff-only`; freeform + structured L2 (deviations, failed bugs, unfinished business) in `handoff-plus-index` | Iteration 2+ |
| 5 | `## Retrieved Project Memory` | `retrieve_relevant_knowledge()` — top-k keyword-matched entries from knowledge-index.md | `handoff-plus-index` mode + index file exists + matches found |
| 6 | `## Accumulated Knowledge` | Static pointer to `.ralph/knowledge-index.md` | `handoff-plus-index` mode + index file exists |
| 7 | `## Skills` | Skill files from `.ralph/skills/` matched by task's `skills` array | When task has skills |
| 8 | `## Output Instructions` | `.ralph/templates/coding-prompt-footer.md` or inline fallback | Always |

### Knowledge Retrieval — `retrieve_relevant_knowledge()`
- Location: `context.sh:291`
- Extracts keywords from task id, title, description, and libraries
- Searches `knowledge-index.md` via awk with category priority: Constraints (1) > Architectural Decisions (2) > Unresolved (3) > Gotchas (4) > Patterns (5)
- Returns max 12 lines sorted by category priority then line order
- Injected into `## Retrieved Project Memory` section — NOT just a pointer

### Section-Aware Truncation — `truncate_to_budget()`
- Location: `context.sh:25`
- Splits prompt into 8 named sections via a single awk pass on `## ` headers
- Truncation priority (lowest priority trimmed first):
  1. Accumulated Knowledge (just a pointer — removed entirely)
  2. Skills (trimmed from end)
  3. Output Instructions (trimmed from end, min 22 chars kept)
  4. Previous Handoff (trimmed from end, min 18 chars kept)
  5. Retrieved Project Memory (trimmed from end)
  6. Retrieved Memory (trimmed from end, min 17 chars kept)
  7. Failure Context (trimmed from end)
  8. Current Task (last resort — hard truncate)
- Budget: `RALPH_CONTEXT_BUDGET_TOKENS` (default 8000) * 4 chars/token

### Mode-Sensitive Handoff Retrieval — `get_prev_handoff_for_mode()`
- `handoff-only`: Returns freeform narrative only
- `handoff-plus-index`: Returns freeform narrative + structured L2 block (deviations, failed bugs, constraints, unfinished business) under a "Structured context from previous iteration" subheader
- CRITICAL: `build_coding_prompt_v2()` must pass `$mode` (not a hardcoded string) to this function

## Knowledge Indexer (compaction.sh)

### Compaction Triggers — `check_compaction_trigger()`
4 triggers evaluated in priority order (first match wins):
1. **Task metadata** — `needs_docs == true` or `libraries` array non-empty
2. **Semantic novelty** — term overlap between next task and recent handoff summaries < `RALPH_NOVELTY_OVERLAP_THRESHOLD` (default 0.25). Uses `build_task_term_signature()` + `build_recent_handoff_term_signature()` + `calculate_term_overlap()`
3. **Byte threshold** — `total_handoff_bytes_since_compaction` > `RALPH_COMPACTION_THRESHOLD_BYTES` (default 32000)
4. **Periodic** — `coding_iterations_since_compaction` >= `RALPH_COMPACTION_INTERVAL` (default 5)

### Post-Indexing Verification — `verify_knowledge_indexes()`
Runs 4 checks after every indexer pass. On any failure, restores pre-indexer snapshots.

| Check | Function | Invariant |
|-------|----------|-----------|
| Header format | `verify_knowledge_index_header()` | `# Knowledge Index` + `Last updated: iteration N (...)` |
| Hard constraints | `verify_hard_constraints_preserved()` | Lines matching `must/must not/never` under `## Constraints` must be preserved OR superseded via `[supersedes: K-<type>-<slug>]` |
| JSON append-only | `verify_json_append_only()` | New JSON array >= old length, no old entries removed, no duplicate iterations |
| ID consistency | `verify_knowledge_index()` | No duplicate active `memory_ids`; all `supersedes` references target existing IDs |

### Memory ID Format
- Pattern: `K-<type>-<slug>` (e.g., `K-constraint-no-force-push`, `K-decision-tag-checkpoints`)
- Types: `constraint`, `decision`, `pattern`, `gotcha`, `unresolved`
- Supersession: `[supersedes: K-<type>-<slug>]` inline in the new entry
- Provenance: `[source: iter N,M]` inline in each entry
- Both formats are checked by verification and consumed by `retrieve_relevant_knowledge()`

### Configuration Variables
| Variable | Default | Location | Description |
|----------|---------|----------|-------------|
| `RALPH_CONTEXT_BUDGET_TOKENS` | 8000 | context.sh / ralph.conf | Token budget for assembled prompts |
| `RALPH_NOVELTY_OVERLAP_THRESHOLD` | 0.25 | compaction.sh / ralph.conf | Term overlap ratio below which novelty trigger fires |
| `RALPH_NOVELTY_RECENT_HANDOFFS` | 3 | compaction.sh / ralph.conf | Number of recent handoffs for novelty comparison |
| `RALPH_COMPACTION_THRESHOLD_BYTES` | 32000 | compaction.sh / ralph.conf | Byte threshold trigger |
| `RALPH_COMPACTION_INTERVAL` | 5 | compaction.sh / ralph.conf | Periodic trigger interval (coding iterations) |

## Telemetry
- Events logged to `.ralph/logs/events.jsonl` as JSONL (`{timestamp, event, message, metadata}`)
- Event types: orchestrator_start/end, iteration_start/end, validation_pass/fail, pause, resume, note, skip_task
- All `emit_event` calls in ralph.sh are guarded with `declare -f` checks for graceful degradation
- Control commands use queue-based format in `.ralph/control/commands.json`: `{"pending": [...]}`

## Dashboard
- Single-file HTML at `.ralph/dashboard.html` (vanilla JS + Tailwind CDN)
- Serve via `python3 .ralph/serve.py --port 8080` from project root
- Polls state.json, plan.json, handoffs, events.jsonl, knowledge-index.json, progress-log.json every 3 seconds
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
- Test files: `tests/<module>.bats` (context.bats, compaction.bats, telemetry.bats, progress-log.bats, integration.bats, etc.)
- Each module has its own test file
- Use `setup()` and `teardown()` for test fixtures
- Test in temporary directories to avoid polluting the project
- Key context engineering tests in `context.bats`: section-aware truncation (8 sections parsed, priority ordering), mode-sensitive handoff (L2 in h+i, freeform-only in h-o), retrieved project memory injection
- Key verification tests in `compaction.bats`: hard constraint supersession via memory ID, constraint drop rejection, novelty trigger thresholds, JSON append-only

## Git
- Commits use the format: `ralph[N]: TASK-ID — description`
- Every successful iteration creates a commit
- Failed iterations roll back to the checkpoint
