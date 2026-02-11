# Ralph Deluxe — Project Conventions

## What This Is

Bash orchestrator that drives Claude Code CLI through structured task plans. Each coding iteration writes a freeform handoff narrative that becomes the primary context for the next iteration. Three modes: `handoff-only` (default), `handoff-plus-index` (adds periodic knowledge indexing), and `agent-orchestrated` (LLM context agent prepares prompts and organizes knowledge every turn).

## Architecture Overview

```
plan.json → ralph.sh main loop → for each task:

  handoff-only / handoff-plus-index modes:
  1. get_next_task()           [plan-ops.sh]    — select task with deps satisfied
  2. check_compaction_trigger() [compaction.sh]  — h+i mode: maybe run indexer
  3. create_checkpoint()       [git-ops.sh]     — save HEAD for rollback
  4. build_coding_prompt_v2()  [context.sh]     — assemble 7-section prompt
  5. run_coding_iteration()    [cli-ops.sh]     — invoke claude CLI
  6. parse_handoff_output()    [cli-ops.sh]     — extract handoff from response
  7. run_validation()          [validation.sh]  — run test/lint commands
  8a. PASS: commit + log + apply_amendments
  8b. FAIL: rollback + generate_failure_context → retry

  agent-orchestrated mode (recommended for quality):
  1. get_next_task()           [plan-ops.sh]    — select task with deps satisfied
  2. create_checkpoint()       [git-ops.sh]     — save HEAD for rollback
  3. run_context_prep()        [agents.sh]      — LLM context agent assembles prompt
     → writes .ralph/context/prepared-prompt.md
     → returns directive (proceed/skip/review/research)
  4. run_coding_iteration()    [cli-ops.sh]     — invoke coding agent with prepared prompt
  5. parse_handoff_output()    [cli-ops.sh]     — extract handoff from response
  6. run_validation()          [validation.sh]  — run test/lint commands
  7a. PASS: commit + log + apply_amendments
  7b. FAIL: rollback + generate_failure_context → retry
  8. run_context_post()        [agents.sh]      — LLM context agent organizes knowledge
     → updates knowledge-index.{md,json}
     → detects stuck patterns, processes coding agent signals
  9. run_agent_passes()        [agents.sh]      — optional: code review, docs, etc.
```

## Module Dependency Map

```
ralph.sh (main) ─── sources all .ralph/lib/*.sh modules
  ├── agents.sh       — multi-agent orchestration: context prep/post, agent passes
  ├── context.sh      — prompt assembly, truncation, knowledge retrieval (h-o/h+i modes)
  ├── compaction.sh   — triggers, indexer, verification (h+i mode; reused by agents.sh)
  ├── cli-ops.sh      — claude CLI invocation, handoff parsing
  ├── validation.sh   — post-iteration test/lint gate
  ├── plan-ops.sh     — task selection, amendments, plan mutation
  ├── git-ops.sh      — checkpoint/rollback/commit
  ├── telemetry.sh    — event stream, operator control commands
  └── progress-log.sh — auto-generated progress logs (calls plan-ops.sh)

serve.py (HTTP) ←→ dashboard.html (polls every 3s)
  Writes: .ralph/control/commands.json (read by telemetry.sh)
  Writes: .ralph/config/ralph.conf (read by ralph.sh)

ralph.sh memory/bootstrap paths
  Reads (optional): .ralph/templates/first-iteration.md
  Reads (legacy compaction): .ralph/templates/memory-prompt.md
```

## Directory Structure

| Path | Purpose |
|------|---------|
| `.ralph/ralph.sh` | Main orchestrator — state machine, main loop, signal handling |
| `.ralph/lib/*.sh` | 9 library modules (sourced by ralph.sh) |
| `.ralph/config/ralph.conf` | Runtime config (mode, thresholds, validation commands) |
| `.ralph/config/agents.json` | Agent pass configuration (context agent settings, optional passes) |
| `.ralph/config/handoff-schema.json` | JSON schema for coding iteration output |
| `.ralph/config/context-prep-schema.json` | JSON schema for context prep agent output |
| `.ralph/config/context-post-schema.json` | JSON schema for context post agent output |
| `.ralph/config/review-agent-schema.json` | JSON schema for code review agent output |
| `.ralph/config/mcp-coding.json` | MCP config for coding iterations |
| `.ralph/config/mcp-context.json` | MCP config for context agent (Context7 for library docs) |
| `.ralph/config/mcp-memory.json` | MCP config for legacy memory/indexer iterations |
| `.ralph/config/memory-output-schema.json` | JSON schema for legacy memory compaction output |
| `.ralph/templates/context-prep-prompt.md` | System prompt for context prep agent (agent-orchestrated mode) |
| `.ralph/templates/context-post-prompt.md` | System prompt for context post agent (agent-orchestrated mode) |
| `.ralph/templates/review-agent-prompt.md` | System prompt for code review agent pass |
| `.ralph/templates/` | Other prompt templates (coding-prompt-footer.md, first-iteration.md, knowledge-index-prompt.md, memory-prompt.md) |
| `.ralph/skills/` | Per-task skill injection files (matched by task.skills[] array) |
| `.ralph/handoffs/` | Raw handoff JSON per iteration (handoff-001.json, etc.) |
| `.ralph/control/commands.json` | Dashboard→orchestrator command queue |
| `.ralph/logs/events.jsonl` | Append-only JSONL telemetry stream |
| `.ralph/logs/validation/` | Per-iteration validation results (iter-N.json) |
| `.ralph/context/prepared-prompt.md` | Prompt assembled by context agent (agent-orchestrated mode) |
| `.ralph/state.json` | Runtime state: iteration, mode, status, compaction counters |
| `.ralph/knowledge-index.md` | Categorized knowledge index (h+i and agent-orchestrated modes) |
| `.ralph/knowledge-index.json` | Iteration-keyed index for dashboard (h+i and agent-orchestrated modes) |
| `.ralph/memory.jsonl` | Legacy append-only memory compaction output (migration compatibility) |
| `.ralph/progress-log.{md,json}` | Auto-generated progress logs |
| `.ralph/dashboard.html` | Single-file operator dashboard (vanilla JS + Tailwind) |
| `.ralph/serve.py` | HTTP server for dashboard |
| `plan.json` | Task plan (project root) |
| `tests/*.bats` | bats-core test suite (unit, integration, and error-handling coverage) |
| `tests/test_helper/common.sh` | Shared bats helper for temp workspace setup/teardown |

## Operating Modes

| Mode | Memory Strategy | Prompt Assembly | Agent Calls/Iter | Compaction | Quality |
|------|----------------|-----------------|-----------------|------------|---------|
| `handoff-only` (default) | Freeform narrative only | Bash (`build_coding_prompt_v2`) | 1 | None | Baseline |
| `handoff-plus-index` | Narrative + knowledge index | Bash (`build_coding_prompt_v2`) | 1-2 | Trigger-based | Better |
| `agent-orchestrated` | LLM-curated context + knowledge | LLM context agent | 2-3+ | Every iteration | Best |

Mode priority: `--mode` CLI flag > `RALPH_MODE` in ralph.conf > default (`handoff-only`)

### Agent-Orchestrated Mode (agents.sh)

Two-agent architecture: a **context agent** prepares pristine context for a **coding agent**, then organizes the coding agent's output into accumulated knowledge. Optional agent passes (code review, documentation) can run after each iteration.

**Agent call sequence per iteration:**
1. **Context prep** (pre-coding): Reads handoffs, knowledge index, failure context. Assembles tailored coding prompt. Detects stuck patterns. Returns directive (proceed/skip/review/research).
2. **Coding agent**: Receives the prepared prompt. Executes the plan step. Writes handoff with gained insights. Can signal back: `request_research`, `request_human_review`, `confidence_level`.
3. **Context post** (post-coding): Processes handoff into knowledge index. Detects failure patterns across iterations. Recommends next action.
4. **Optional passes**: Configurable agents (e.g., code review with cheaper model) run based on trigger conditions.

**Context agent I/O**: Receives a lightweight manifest with file pointers (not full content), plus research requests and signals from the previous coding agent. Uses built-in Read tools and MCP tools (Context7 for library docs) to research everything the coding agent will need. Writes `prepared-prompt.md` as side effect. Returns directives via JSON schema. The coding agent has NO MCP tools — everything it needs must be in the prepared prompt.

**Research loop**: When a task involves libraries (`needs_docs: true` or `libraries[]`), the context agent uses Context7 to fetch API documentation and includes relevant excerpts in the coding prompt. When the coding agent signals `request_research`, those topics are forwarded to the context agent's next prep pass for investigation. This ensures the coding agent never has to hunt for information.

**Stuck detection**: Context agent analyzes retry counts, failure patterns, and consecutive handoff narratives. Can recommend skipping a task, requesting human review, or modifying the plan.

**Coding agent signals** (new handoff schema fields):
- `request_research`: Topics for context agent to research next iteration
- `request_human_review`: Signal that human judgment is needed
- `confidence_level`: Self-assessed output confidence (high/medium/low)

**Agent pass framework** (`.ralph/config/agents.json`):
- Passes configured with: name, model, trigger, max_turns, prompt template, schema
- Triggers: `always`, `on_success`, `on_failure`, `periodic:N`
- Passes are non-fatal: failures logged but don't block the main loop
- Code review pass included as skeleton (disabled by default)

## The 7-Section Prompt (`build_coding_prompt_v2` in context.sh)

Section headers MUST be `## <Name>` exactly — the truncation awk parser matches these.

| # | Section | Source | Present When | Truncation Priority |
|---|---------|--------|--------------|---------------------|
| 1 | `## Current Task` | plan.json task | Always | 7 (last resort) |
| 2 | `## Failure Context` | validation output | Retry only | 6 (removed entirely) |
| 3 | `## Retrieved Memory` | latest handoff constraints + decisions | Always | 5 (removed entirely) |
| 4 | `## Previous Handoff` | `get_prev_handoff_for_mode()` or first-iteration.md | Iteration 1+ | 3 (removed entirely) |
| 5 | `## Retrieved Project Memory` | Full `.ralph/knowledge-index.md` inlined | h+i mode + index exists | 4 (removed entirely) |
| 6 | `## Skills` | `.ralph/skills/<name>.md` | Task has skills[] | 1 (removed first) |
| 7 | `## Output Instructions` | `coding-prompt-footer.md` or inline fallback | Always | 2 (removed entirely) |

**CRITICAL**: `build_coding_prompt_v2()` must pass `$mode` (not a hardcoded string) to `get_prev_handoff_for_mode()`. Tests verify this.

**Function signature**: `build_coding_prompt_v2(task_json, mode, skills_content, failure_context, first_iteration_context)`. The 5th parameter is optional — on iteration 1, ralph.sh passes the contents of `first-iteration.md`; it's injected into `## Previous Handoff` when no prior handoffs exist.

### Mode-Sensitive Handoff Retrieval

- `handoff-only`: Returns freeform narrative only
- `handoff-plus-index`: Returns freeform + structured L2 (deviations, constraints, decisions) under "### Structured context from previous iteration"

### Knowledge Index Inlining

In `handoff-plus-index` mode, the full contents of `.ralph/knowledge-index.md` are inlined into the `## Retrieved Project Memory` section. This replaces the previous keyword-matching approach (`retrieve_relevant_knowledge()`) which capped output at 12 lines. The HPI token budget (16000, double the base 8000) accommodates the larger prompt. If the index grows too large, the truncation system removes the entire section and the coding agent can still `Read` the file directly.

`retrieve_relevant_knowledge()` is retained for backward compatibility but is no longer called by `build_coding_prompt_v2()`.

## Knowledge Indexer (compaction.sh) — h+i mode only

### Compaction Triggers (first match wins)

1. **Task metadata** — `needs_docs == true` or `libraries[]` non-empty
2. **Semantic novelty** — term overlap < `RALPH_NOVELTY_OVERLAP_THRESHOLD` (0.25)
3. **Byte threshold** — accumulated bytes > `RALPH_COMPACTION_THRESHOLD_BYTES` (32000)
4. **Periodic** — iterations since compaction >= `RALPH_COMPACTION_INTERVAL` (5)

### Post-Indexer Verification (all must pass or rollback)

| Check | Invariant |
|-------|-----------|
| `verify_knowledge_index_header()` | `# Knowledge Index` + `Last updated: iteration N (...)` |
| `verify_hard_constraints_preserved()` | `must/must not/never` lines under `## Constraints` preserved or superseded via `[supersedes: K-<type>-<slug>]` |
| `verify_json_append_only()` | Array length >= old, no entries removed, no duplicate iterations |
| `verify_knowledge_index()` | No duplicate active `memory_ids`; all `supersedes` targets exist |

### Memory ID Format

Pattern: `K-<type>-<slug>` — types: `constraint`, `decision`, `pattern`, `gotcha`, `unresolved`
Supersession: `[supersedes: K-<type>-<slug>]` inline. Provenance: `[source: iter N,M]` inline.

## Handoff Schema

Required: `summary` (one-line), `freeform` (full narrative briefing — most important field).
Structured fields: `task_completed`, `deviations`, `bugs_encountered`, `architectural_notes`, `constraints_discovered`, `files_touched`, `plan_amendments`, `tests_added`, `unfinished_business`, `recommendations`.
Signal fields (agent-orchestrated mode): `request_research` (string[]), `request_human_review` ({needed, reason}), `confidence_level` (high/medium/low).

## Plan Amendments (plan-ops.sh)

Safety guardrails:
- Max 3 amendments per iteration
- Cannot modify current task's status
- Cannot remove tasks with status "done"
- Creates plan.json.bak before mutation
- All mutations logged to .ralph/logs/amendments.log

## Validation (validation.sh)

Strategies: `strict` (all pass), `lenient` (tests pass, lint OK to fail), `tests_only` (lint ignored).
Unknown commands default to "test" classification (fail-safe).
Failure context truncated to 500 chars per check to conserve prompt budget.

## Configuration

| Variable | Default | Used By |
|----------|---------|---------|
| `RALPH_CONTEXT_BUDGET_TOKENS` | 8000 | context.sh (handoff-only mode budget) |
| `RALPH_CONTEXT_BUDGET_TOKENS_HPI` | 16000 | context.sh (handoff-plus-index mode budget) |
| `RALPH_NOVELTY_OVERLAP_THRESHOLD` | 0.25 | compaction.sh |
| `RALPH_NOVELTY_RECENT_HANDOFFS` | 3 | compaction.sh |
| `RALPH_COMPACTION_THRESHOLD_BYTES` | 32000 | compaction.sh |
| `RALPH_COMPACTION_INTERVAL` | 5 | compaction.sh |
| `RALPH_VALIDATION_STRATEGY` | strict | validation.sh |
| `RALPH_MAX_ITERATIONS` | 50 | ralph.sh |
| `RALPH_DEFAULT_MAX_TURNS` | 200 | cli-ops.sh (safety-net `--max-turns` for coding agent) |
| `RALPH_MIN_DELAY_SECONDS` | 30 | ralph.sh |
| `RALPH_CONTEXT_AGENT_MODEL` | "" (default) | agents.sh (model override for context agent) |
| `RALPH_AGENT_PASSES_ENABLED` | true | agents.sh (enable/disable optional passes) |

### Terminology: Turns vs Retries

- **`--max-turns`** (Claude CLI flag): Internal tool-use round-trips within a single CLI invocation. The coding agent uses `RALPH_DEFAULT_MAX_TURNS` (200) as a system-level safety net. This is NOT configurable per-task — the agent works freely until it produces structured output.
- **`max_retries`** (plan.json task field): How many full task attempts the orchestrator will make. Each retry is a complete iteration cycle: prompt assembly → coding agent → validation gate → commit or rollback.
- **`max_turns`** in `agents.json`: System-level config for context agents and agent passes. Separate from the coding agent's turn limit.

## Documentation Standards for LLM Agents

This codebase is maintained exclusively by LLM coding agents. All documentation follows patterns optimized for LLM context consumption — maximizing intent clarity per token while making dependency gaps impossible to miss.

### Module Header Template

Every `.sh` file starts with a block comment containing these sections in order:

```bash
# PURPOSE: What this module does and why it exists (1-3 lines)
# DEPENDENCIES:
#   Called by: <parent modules/functions>
#   Calls: <child modules/functions>
#   Globals read: <UPPER_SNAKE variables consumed>
#   Globals written: <UPPER_SNAKE variables mutated>
#   Files read: <paths consumed>
#   Files written: <paths mutated>
# DATA FLOW: How data enters, transforms, and exits this module
# INVARIANTS: What must always be true for this module to work correctly
```

### Function Comment Markers

| Marker | Use When | Example |
|--------|----------|---------|
| `CALLER:` | Function has non-obvious callers | `# CALLER: main loop in ralph.sh` |
| `SIDE EFFECT:` | Function mutates state beyond return value | `# SIDE EFFECT: writes .ralph/state.json` |
| `CRITICAL:` | Invariant that breaks downstream if violated | `# CRITICAL: header must be exactly "## Name"` |
| `INVARIANT:` | Condition that must hold pre/post execution | `# INVARIANT: array length >= previous` |
| `WHY:` | Rationale for non-obvious design choices | `# WHY: double-parse because .result is a JSON string` |

### Design Principles

1. **Intent over mechanics** — Lead with WHY, not WHAT. LLMs can read code; they need the reasoning behind it.
2. **Explicit dependencies** — Every function's inputs, outputs, and side effects declared upfront. No hidden coupling.
3. **Contracts first** — Preconditions, postconditions, and invariants stated before implementation details.
4. **Cross-reference liberally** — Name the caller, the callee, the config variable. Make the dependency graph navigable from any node.
5. **Token-efficient language** — Dense, factual statements. No filler words, no restating what code already says.
6. **Fail-path documentation** — Document what happens on failure, not just success. Rollback paths, fallback behaviors, error propagation.

### What NOT to Comment

- Variable assignments, increments, simple conditionals — the LLM reads these directly
- Restatements of what the code does (`# increment counter` above `counter=$((counter + 1))`)
- Type information inferable from context or naming conventions
- Boilerplate explanations of standard library functions

### CLAUDE.md Structure Guidelines

This file is loaded into the LLM system prompt. Structure it for rapid orientation:
- Lead with architecture (data flow diagram, not prose)
- Module dependency map (who sources/calls whom)
- Combined tables over separate sections (e.g., section + truncation priority in one table)
- Configuration tables include "Used By" column for traceability
- Dense, cross-referenced format — every concept linked to its implementation location

## Coding Conventions

### Bash
- `#!/usr/bin/env bash` + `set -euo pipefail` in all scripts
- Functions return 0 success, non-zero failure. Log via shared `log()` from ralph.sh
- UPPER_SNAKE for constants/config, lower_snake for locals. Quote all `"$vars"`
- `[[ ]]` conditionals. Each lib module tested independently via bats
- `declare -f` guards on cross-module function calls for graceful degradation

### JSON (jq)
- Simple composable filters. `// "default"` for optional fields
- All config files validate with `jq . < file.json`

### Git
- Commit format: `ralph[N]: TASK-ID — description`
- Every success → commit. Every failure → rollback to checkpoint

## Testing

Framework: bats-core. Files: `tests/<module>.bats`. Temp dirs for isolation.

Key test coverage:
- `agents.bats`: context prep/post input building, directive handling, pass triggers, agent config loading, dry-run flows, handoff signal fields
- `context.bats`: 7-section parsing, truncation priority, mode-sensitive handoff, knowledge index inlining, budget-per-mode
- `compaction.bats`: constraint supersession, constraint drop rejection, novelty thresholds, JSON append-only
- `plan-ops.bats`: dependency resolution, amendment guardrails (max 3, no done removal)
- `integration.bats`: full orchestrator cycles, state management, validation flow
- `validation.bats`: strategy evaluation, command classification, failure context generation
- `error-handling.bats`: retry/rollback resilience paths and interrupted-run behavior

## Dashboard Screenshots

Single command: `bash screenshots/capture.sh` or `npm run screenshots`

| Path | Purpose |
|------|---------|
| `screenshots/capture.sh` | Entry point — auto-detects Playwright + Chromium, builds Tailwind CSS if stale, runs capture |
| `screenshots/take-screenshots.mjs` | Playwright script — installs mock data, starts serve.py, captures 6 views, cleans up |
| `screenshots/mock-data/` | Mock data files (12 handoffs, plan, state, events, knowledge index, progress log) |
| `screenshots/tailwind.config.js` | Tailwind config scoped to dashboard.html |
| `screenshots/tailwind-generated.css` | Built CSS (gitignored-safe to regenerate) |
| `screenshots/*.png` | Output screenshots |

Environment overrides (all optional): `PLAYWRIGHT_MODULE`, `CHROMIUM_BIN`, `SCREENSHOT_PORT`

Key constraints:
- External CDN is unreachable — Tailwind CSS is built locally and injected via `page.route()` intercept
- Chromium requires `--single-process --no-sandbox --disable-gpu --disable-dev-shm-usage` flags
- Mock data is installed into live paths with `.screenshot-bak` backup/restore — originals are never lost
- `tailwind.config.js` content path is `../.ralph/dashboard.html` (relative to `screenshots/` dir)

## Telemetry & Control

- Events: append-only JSONL at `.ralph/logs/events.jsonl`
- Event types: `orchestrator_start/end`, `iteration_start/end`, `validation_pass/fail`, `pause`, `resume`, `note`, `skip_task`, `stuck_detected`, `failure_pattern`, `human_review_requested`, `agent_pass`
- All `emit_event` calls guarded by `declare -f` for graceful degradation
- Control: queue-based via `.ralph/control/commands.json` (`{"pending": [...]}`)
- Dashboard POSTs commands → serve.py enqueues → orchestrator polls at loop top
