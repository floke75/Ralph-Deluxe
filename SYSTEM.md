# Ralph Deluxe — Complete System Documentation for LLM Agents

This document provides a complete, self-contained understanding of the Ralph Deluxe codebase. An LLM reading this document should be able to understand every component, data flow, invariant, and behavioral nuance without examining the source code.

---

## 1. System Identity

Ralph Deluxe is a **Bash orchestrator** that drives the Claude Code CLI through structured task plans. It reads a `plan.json` containing ordered tasks with dependencies, then iterates through them one at a time: assembling a context-rich prompt, invoking Claude to implement the task, validating the output, and either committing the result or rolling back and retrying. Between iterations, the coding agent writes a **handoff document** — a structured JSON narrative that becomes the primary memory artifact for the next iteration.

The system runs entirely from the command line. There is no database. All state lives in JSON files on disk. A Python HTTP server (`serve.py`) bridges a single-page HTML dashboard to these files for operator observability and control.

---

## 2. High-Level Architecture

```
plan.json ──> ralph.sh main loop ──> for each task:
  │
  ├── [Mode: handoff-only / handoff-plus-index]
  │   1. get_next_task()            → plan-ops.sh
  │   2. check_compaction_trigger() → compaction.sh (h+i only)
  │   3. create_checkpoint()        → git-ops.sh
  │   4. build_coding_prompt_v2()   → context.sh
  │   5. run_coding_iteration()     → cli-ops.sh
  │   6. parse_handoff_output()     → cli-ops.sh
  │   7. run_validation()           → validation.sh
  │   8a. PASS: commit + log + apply_amendments
  │   8b. FAIL: rollback + generate_failure_context → retry
  │
  └── [Mode: agent-orchestrated]
      1. get_next_task()            → plan-ops.sh
      2. create_checkpoint()        → git-ops.sh
      3. run_context_prep()         → agents.sh (LLM context agent)
         → writes .ralph/context/prepared-prompt.md
         → returns directive (proceed/skip/review/research)
      4. run_coding_iteration()     → cli-ops.sh
      5. parse_handoff_output()     → cli-ops.sh
      6. run_validation()           → validation.sh
      7a. PASS: commit + log + apply_amendments
      7b. FAIL: rollback + generate_failure_context → retry
      8. run_context_post()         → agents.sh (knowledge organization)
      9. run_agent_passes()         → agents.sh (optional: code review)
```

---

## 3. Operating Modes

Ralph supports three operating modes, each representing a different memory and context-assembly strategy. Mode is resolved with this priority: `--mode` CLI flag > `RALPH_MODE` in `ralph.conf` > default `"handoff-only"`.

### 3.1 handoff-only (default)

- **Memory**: The freeform narrative field of the previous handoff is the sole inter-iteration context.
- **Prompt assembly**: Done entirely in Bash by `build_coding_prompt_v2()` in `context.sh`.
- **Token budget**: 8000 tokens (`RALPH_CONTEXT_BUDGET_TOKENS`).
- **Compaction**: None. No knowledge index is maintained.
- **Agent calls per iteration**: 1 (coding only).
- **Best for**: Short projects (< 10 iterations) where handoff drift isn't a concern.

### 3.2 handoff-plus-index

- **Memory**: Freeform narrative + a persistent knowledge index (`knowledge-index.md`/`.json`) that accumulates constraints, decisions, patterns, and gotchas across all iterations.
- **Prompt assembly**: Bash (`build_coding_prompt_v2()`), with the full knowledge index inlined into a `## Retrieved Project Memory` section.
- **Token budget**: 16000 tokens (`RALPH_CONTEXT_BUDGET_TOKENS_HPI`), double the base, to accommodate the inlined index.
- **Compaction**: Trigger-based. Before certain iterations, a knowledge indexer (Claude invoked as a memory agent) updates `knowledge-index.md`/`.json` from recent handoffs.
- **Agent calls per iteration**: 1-2 (coding + optional indexer).
- **Best for**: Medium-length projects where key decisions need to persist beyond the handoff window.

### 3.3 agent-orchestrated

- **Memory**: LLM-curated context. A dedicated context agent reads all available artifacts (handoffs, knowledge index, failure context, validation logs) and assembles a tailored prompt for the coding agent. After coding, the same context agent organizes knowledge.
- **Prompt assembly**: Done by the context agent (an LLM). It writes `prepared-prompt.md` which is piped to the coding agent.
- **Compaction**: Every iteration (the context post agent updates the knowledge index after each coding pass).
- **Agent calls per iteration**: 2-3+ (context prep + coding + context post + optional passes like code review).
- **Best for**: Long or complex projects where context quality is critical.

---

## 4. Module Dependency Map

```
ralph.sh (main orchestrator)
  ├── sources all .ralph/lib/*.sh modules via glob
  │
  ├── agents.sh        Multi-agent orchestration
  │   ├── calls: compaction.sh (snapshot/verify/restore, update_compaction_state)
  │   ├── calls: telemetry.sh (emit_event, guarded)
  │   └── calls: cli-ops.sh (run_coding_iteration, parse_handoff_output)
  │
  ├── cli-ops.sh       Claude CLI invocation and response parsing
  │   └── calls: `claude` binary
  │
  ├── compaction.sh    Knowledge indexing, triggers, verification
  │   ├── calls: cli-ops.sh (run_memory_iteration)
  │   └── reads: handoffs, state.json, knowledge-index files
  │
  ├── context.sh       Prompt assembly and truncation (non-agent modes)
  │   └── reads: handoffs, knowledge-index.md, skills files, templates
  │
  ├── git-ops.sh       Checkpoint, rollback, commit
  │   └── calls: git CLI
  │
  ├── plan-ops.sh      Task selection, status, amendments
  │   └── reads/writes: plan.json
  │
  ├── progress-log.sh  Dual-format progress logging
  │   ├── calls: plan-ops.sh (get_task_by_id)
  │   └── writes: progress-log.md, progress-log.json
  │
  ├── telemetry.sh     Event stream + operator control plane
  │   ├── calls: plan-ops.sh (set_task_status for skip-task)
  │   └── writes: events.jsonl, reads/clears commands.json
  │
  └── validation.sh    Post-iteration test/lint gate
      └── writes: validation/iter-N.json

serve.py (HTTP server)
  ├── serves: static files from project root
  ├── reads: state.json, plan.json, handoffs, events.jsonl
  └── writes: commands.json, ralph.conf

dashboard.html (browser UI)
  ├── polls: serve.py every 3s
  └── sends: POST /api/command, POST /api/settings
```

---

## 5. The Main Loop (ralph.sh)

### 5.1 Startup Sequence

1. **`parse_args()`** — Captures CLI flags (`--mode`, `--max-iterations`, `--plan`, `--dry-run`, `--resume`). Saves `MODE` before config load so CLI can override config.
2. **`load_config()`** — Sources `ralph.conf` as a shell file, setting globals like `RALPH_MODE`, `RALPH_VALIDATION_COMMANDS`, etc.
3. **Mode resolution** — Priority: CLI `--mode` > `RALPH_MODE` from config > `"handoff-only"` default.
4. **`source_libs()`** — Globs and sources all `.ralph/lib/*.sh` files. This defines all library functions. Modules are sourced AFTER config load so they can read config globals at source time.
5. **Subsystem initialization** — `init_control_file()`, `init_progress_log()`, `emit_event("orchestrator_start", ...)`. All guarded with `declare -f` so startup doesn't fail if a module is missing.
6. **`ensure_clean_state()`** — Auto-commits any dirty working tree so checkpoint/rollback has a clean baseline. Without this, the first rollback would destroy pre-existing uncommitted work.
7. **State initialization** — Sets `current_iteration=0`, `status="running"`, `started_at`, `mode` in `state.json`. On `--resume`, reads existing iteration counter instead.

### 5.2 Iteration Lifecycle

Each iteration follows this sequence:

1. **Shutdown check** — `SHUTTING_DOWN` flag set by signal handler.
2. **Operator commands** — `check_and_handle_commands()` processes pause/resume/skip/inject-note from dashboard. Blocks in a polling loop if paused.
3. **Plan completion check** — `is_plan_complete()` returns true when all tasks are done or skipped.
4. **Task selection** — `get_next_task()` returns the first pending task whose `depends_on` are all in "done" status. Returns empty if all pending tasks have unmet dependencies (status becomes "blocked").
5. **Increment iteration** — Updates `current_iteration` and `last_task_id` in state.json.
6. **Mode-dependent pre-task processing**:
   - `handoff-plus-index`: `check_compaction_trigger()` → maybe `run_knowledge_indexer()`
   - `agent-orchestrated`: No pre-task step (context agent handles this internally)
   - `handoff-only`: Nothing
7. **Mark task in-progress** — `set_task_status(plan_file, task_id, "in_progress")`
8. **Create git checkpoint** — `create_checkpoint()` captures HEAD SHA for potential rollback.
9. **Run coding cycle** — Mode-dependent:
   - Non-agent modes: `run_coding_cycle()` (Bash prompt assembly → Claude CLI → handoff parse)
   - Agent-orchestrated: `run_agent_coding_cycle()` (context prep → Claude CLI → handoff parse)
10. **Run validation** — `run_validation()` executes configured commands, applies strategy, writes result.
11. **Branch on validation result**:
    - **PASS**: `commit_iteration()`, `set_task_status("done")`, `append_progress_entry()`, `apply_amendments()`
    - **FAIL**: `rollback_to_checkpoint()`, `increment_retry_count()`, `generate_failure_context()` → save to `failure-context.md`
12. **Post-iteration (agent-orchestrated only)**:
    - `run_context_post()` — Knowledge organization
    - `run_agent_passes()` — Optional passes (code review, etc.)
13. **Rate limit delay** — `sleep RALPH_MIN_DELAY_SECONDS` (default 30s).

### 5.3 Terminal States

The loop exits when:
- **All tasks complete** — status = `"complete"`
- **All pending tasks blocked** — status = `"blocked"` (unmet dependencies)
- **Max iterations reached** — status = `"max_iterations_reached"`
- **Signal received** — status = `"interrupted"` (SIGINT/SIGTERM)
- **Operator pauses and context agent requests human review** — status = `"paused"`

### 5.4 Signal Handling

`shutdown_handler()` catches SIGINT/SIGTERM. It:
1. Sets `SHUTTING_DOWN=true` (reentrant guard prevents double cleanup)
2. Emits `orchestrator_end` event (guarded with `declare -f`)
3. Sets state to `"interrupted"`
4. Exits with code 130

### 5.5 Dry Run Mode

When `--dry-run` is active, the coding cycle runs but Claude CLI returns a mock response. This exercises the full pipeline (prompt assembly, handoff parsing, progress logging, plan mutation) without API calls. Even compaction triggers and knowledge indexing run in dry-run mode for pipeline verification.

---

## 6. Prompt Assembly (context.sh)

### 6.1 The 7-Section Prompt

`build_coding_prompt_v2(task_json, mode, skills_content, failure_context, first_iteration_context)` assembles a markdown prompt with 7 named sections. The section headers are **parser-sensitive literals** — the truncation engine's awk parser matches them exactly. Renaming any header silently breaks truncation.

| # | Section Header | Source | Present When | Truncation Priority |
|---|----------------|--------|--------------|---------------------|
| 1 | `## Current Task` | plan.json task object | Always | 7 (last resort) |
| 2 | `## Failure Context` | validation output | Retry only | 6 |
| 3 | `## Retrieved Memory` | Constraints + decisions from latest handoff | Always | 5 |
| 4 | `## Previous Handoff` | `get_prev_handoff_for_mode()` or first-iteration.md | Always | 3 |
| 5 | `## Retrieved Project Memory` | Full `knowledge-index.md` inlined | h+i mode only | 4 |
| 6 | `## Skills` | `.ralph/skills/<name>.md` files | Task has skills[] | 1 (first removed) |
| 7 | `## Output Instructions` | `coding-prompt-footer.md` or inline fallback | Always | 2 |

### 6.2 Section Content Details

**Section 1 — Current Task**: Extracted from the plan.json task object. Includes ID, title, description, and acceptance criteria formatted as a markdown checklist.

**Section 2 — Failure Context**: Only present on retry iterations. Contains the output of `generate_failure_context()` from validation.sh — failed commands and their truncated (500-char) error output under a `### Validation Failures` sub-header. The `###` level avoids conflicting with the parent `##` header.

**Section 3 — Retrieved Memory**: Constraints and architectural decisions extracted from the latest handoff JSON. Two sub-sections: `### Constraints` (each constraint + workaround/impact) and `### Decisions` (architectural notes). Falls back to "No retrieved memory available." when no handoffs exist.

**Section 4 — Previous Handoff**: Mode-sensitive via `get_prev_handoff_for_mode()`:
- `handoff-only`: Returns only the `.freeform` narrative field from the latest handoff.
- `handoff-plus-index`: Returns the freeform narrative PLUS structured L2 data (task ID, decisions, constraints) under a `### Structured context from previous iteration` sub-header.
- On iteration 1: Injects `first-iteration.md` content (onboarding guidance for the very first pass).
- **Critical invariant**: `build_coding_prompt_v2()` must pass the `$mode` variable, not a hardcoded string. Tests verify this.

**Section 5 — Retrieved Project Memory**: Only present in `handoff-plus-index` mode when `knowledge-index.md` exists. The full file contents are inlined (typically 20-40 lines / ~1500-2500 tokens). This guarantees all hard constraints are present without keyword matching. If the index grows too large, truncation removes this entire section, and the coding agent can still `Read` the file directly.

**Section 6 — Skills**: Task-specific convention files from `.ralph/skills/`. Loaded by `load_skills()` which reads each file named in the task's `skills[]` array from the skills directory. Missing skill files are logged as warnings but non-fatal.

**Section 7 — Output Instructions**: Loaded from `.ralph/templates/coding-prompt-footer.md`. Falls back to `coding-prompt.md`, then to a hardcoded inline template. Instructs the coding agent on handoff document format.

### 6.3 Truncation System

`truncate_to_budget(content, budget_tokens)` enforces token limits via section-aware truncation:

1. **Budget check**: If content fits within `budget_tokens * 4` characters, pass through unchanged. The `chars / 4` heuristic approximates tokens.
2. **Section parsing**: An awk pass splits content into 7 named sections by matching exact `## Header` lines.
3. **Iterative trimming**: Sections are removed entirely (not partially) in priority order until within budget:
   - Skills → Output Instructions → Previous Handoff → Retrieved Project Memory → Retrieved Memory → Failure Context → Current Task (hard truncate as last resort)
4. **Metadata emission**: Emits `[[TRUNCATION_METADATA]]` JSON to stderr (consumed by tests/debugging, NOT included in the prompt sent to Claude).
5. **Fallback**: If the awk parser fails to find `## Current Task`, falls back to raw character truncation.

### 6.4 Token Budgets

| Mode | Budget Variable | Default | Rationale |
|------|----------------|---------|-----------|
| handoff-only | `RALPH_CONTEXT_BUDGET_TOKENS` | 8000 | No knowledge index, minimal context |
| handoff-plus-index | `RALPH_CONTEXT_BUDGET_TOKENS_HPI` | 16000 | Accommodates full inlined knowledge index |
| agent-orchestrated | N/A | Context agent decides | No bash truncation; agent manages budget |

### 6.5 Knowledge Retrieval (Legacy)

`retrieve_relevant_knowledge(task_json, index_file, max_lines)` performs keyword-based lookup against `knowledge-index.md`. It:
1. Extracts search terms from task ID, title, description, and libraries
2. Searches the index file via awk, matching terms against lines
3. Tags matches by category heading
4. Sorts by category priority: Constraints (1) > Architectural Decisions (2) > Unresolved (3) > Gotchas (4) > Patterns (5)
5. Returns max 12 lines

**Note**: This function is retained for backward compatibility but is **no longer called** by `build_coding_prompt_v2()`, which now inlines the full knowledge index instead.

---

## 7. Claude CLI Interaction (cli-ops.sh)

### 7.1 Coding Iteration Invocation

`run_coding_iteration(prompt, task_json, skills_file)` invokes the `claude` CLI:

**CLI arguments constructed**:
- `-p` — Pipe mode (stdin prompt)
- `--output-format json` — JSON response envelope
- `--json-schema <contents of handoff-schema.json>` — Enforces structured output
- `--strict-mcp-config` + `--mcp-config .ralph/config/mcp-coding.json` — MCP tool configuration
- `--max-turns <task.max_turns // 20>` — Per-task turn limit
- `--dangerously-skip-permissions` — When `RALPH_SKIP_PERMISSIONS=true` (default)
- `--append-system-prompt-file <skills_file>` — Optional per-task skill injection

The prompt is piped to stdin. The response is a JSON envelope.

### 7.2 Memory/Indexer Iteration

`run_memory_iteration(prompt)` is similar but uses:
- `memory-output-schema.json` instead of `handoff-schema.json`
- `mcp-memory.json` instead of `mcp-coding.json`
- `RALPH_COMPACTION_MAX_TURNS` (default 10) for turn limit

Used by the legacy compaction cycle and the knowledge indexer.

### 7.3 Response Envelope and Double-Parse

The `claude` CLI wraps structured output in a JSON envelope:
```json
{
  "type": "result",
  "subtype": "success",
  "cost_usd": 0.05,
  "duration_ms": 15000,
  "duration_api_ms": 12000,
  "is_error": false,
  "num_turns": 3,
  "result": "{\"task_completed\":{...},\"freeform\":\"...\"}"
}
```

The `.result` field contains the handoff JSON **as a string** — it must be parsed twice:
1. First parse: Extract `.result` from the envelope
2. Second parse: Parse the string as JSON to get the actual handoff object

`parse_handoff_output(response)` handles this double-parse. It validates the inner JSON is well-formed before returning it.

### 7.4 Handoff Persistence

`save_handoff(handoff_json, iteration)` writes to `.ralph/handoffs/handoff-NNN.json` with zero-padded iteration numbers (e.g., `handoff-001.json`, `handoff-012.json`). Returns the file path via stdout.

### 7.5 Response Metadata

`extract_response_metadata(response)` extracts cost, duration, turn count, and error status from the envelope for logging/telemetry.

### 7.6 MCP Configurations

Three MCP config files control which tools each agent type has access to:

| Config File | Used By | Tools Available |
|------------|---------|----------------|
| `mcp-coding.json` | Coding iterations | Empty `mcpServers: {}` — coding agent has NO MCP tools |
| `mcp-context.json` | Context agent (prep/post) | Context7 (`@upstash/context7-mcp`) for library docs |
| `mcp-memory.json` | Knowledge indexer | Empty (relies on built-in file tools) |

**Critical design choice**: The coding agent has NO MCP tools. Everything it needs must be in the prompt. The context agent fetches library docs via Context7 and includes them in the prepared prompt.

---

## 8. Handoff Documents

### 8.1 Schema Structure

Handoff documents are JSON objects conforming to `handoff-schema.json`. Every coding iteration produces one.

**Required fields**:

| Field | Type | Purpose |
|-------|------|---------|
| `task_completed` | `{task_id, summary, fully_complete}` | Task completion status |
| `deviations` | `[{planned, actual, reason}]` | Plan deviations |
| `bugs_encountered` | `[{description, resolution, resolved}]` | Bugs found |
| `architectural_notes` | `[string]` | Design decisions made |
| `unfinished_business` | `[{item, reason, priority}]` | Incomplete work |
| `recommendations` | `[string]` | Suggestions for next iteration |
| `files_touched` | `[{path, action}]` | Files created/modified/deleted |
| `plan_amendments` | `[{action, task_id, task, changes, after, reason}]` | Proposed plan changes |
| `tests_added` | `[{file, test_names}]` | Tests written |
| `constraints_discovered` | `[{constraint, impact, workaround?}]` | Discovered limitations |
| `summary` | `string` | One-line summary |
| `freeform` | `string (minLength: 50)` | **Most important field** — full narrative briefing |

**Signal fields** (agent-orchestrated mode):

| Field | Type | Purpose |
|-------|------|---------|
| `request_research` | `[string]` | Topics for context agent to research next iteration |
| `request_human_review` | `{needed, reason}` | Signal that human judgment is needed |
| `confidence_level` | `"high" \| "medium" \| "low"` | Self-assessed output quality |

### 8.2 The Freeform Field

The `freeform` field is the primary memory mechanism. It's a free-text narrative (minimum 50 characters) where the coding agent briefs the next iteration on what happened, why, what's fragile, and what to do next. In `handoff-only` mode, this is the ONLY inter-iteration context. The coding prompt footer instructs the agent to write it "as if briefing a colleague who's picking up tomorrow."

### 8.3 Signal Flow (Agent-Orchestrated Mode)

```
Coding Agent writes handoff with:
  request_research: ["How to use bats assert_output"]
  request_human_review: {needed: true, reason: "API key required"}
  confidence_level: "low"
          │
          ▼
Context Post Agent processes signals:
  - Logs research requests
  - Notes in knowledge index
  - Returns recommendation
          │
          ▼
Next Iteration Context Prep Agent:
  - Reads request_research from previous handoff
  - Fetches docs via Context7
  - Includes findings in prepared-prompt.md
  - Checks human_review signal → may return directive
```

---

## 9. Knowledge Compaction (compaction.sh)

### 9.1 Compaction Triggers

In `handoff-plus-index` mode, `check_compaction_trigger()` evaluates whether to run the knowledge indexer before the current iteration. Triggers are checked in order; first match wins:

| Priority | Trigger | Condition | Rationale |
|----------|---------|-----------|-----------|
| 1 | Task metadata | `needs_docs == true` OR `libraries[]` non-empty | Task needs external docs; indexer fetches them |
| 2 | Semantic novelty | Term overlap between task and recent 3 handoffs < 0.25 | New topic area; past handoffs won't help |
| 3 | Byte threshold | Accumulated handoff bytes > 32000 | Too much unindexed data |
| 4 | Periodic | Iterations since last compaction >= 5 | Regular indexing cadence |

**Novelty calculation**: `build_task_term_signature()` and `build_recent_handoff_term_signature()` tokenize text into sorted unique lowercase terms (length > 2). `calculate_term_overlap()` computes `|intersection| / |task_terms|`. Overlap < threshold means the task diverges significantly from recent work.

### 9.2 Knowledge Indexer Flow

`run_knowledge_indexer(task_json)`:
1. Collects L2 data from all handoffs since last compaction (`build_compaction_input()`)
2. Builds prompt from template + existing index + new handoff data (`build_indexer_prompt()`)
3. Snapshots current `knowledge-index.md`/`.json` for rollback
4. Invokes `run_memory_iteration(prompt)` — Claude writes updated index files via file tools
5. Runs 4 verification checks; rolls back on any failure
6. Resets compaction counters in state.json on success

### 9.3 L1/L2/L3 Extraction Levels

| Level | Function | Size | Content | Used By |
|-------|----------|------|---------|---------|
| L1 | `extract_l1()` | ~20-50 tokens | `[task-id] Summary. Complete/Partial. N files.` | Historical context lists |
| L2 | `extract_l2()` | ~200-500 tokens | JSON: task, decisions, deviations, constraints, failed, unfinished | Previous iteration context |
| L3 | `extract_l3()` | 1 line | File path | Deep-dive lookup |

### 9.4 Post-Indexer Verification

All 4 checks must pass or the index files are rolled back to their pre-indexer snapshot:

**Check 1 — Header format** (`verify_knowledge_index_header`):
- File must start with `# Knowledge Index`
- Second line must match `Last updated: iteration N (...)` where N is a digit

**Check 2 — Hard constraint preservation** (`verify_hard_constraints_preserved`):
- Any line under `## Constraints` in the PREVIOUS index containing `must`, `must not`, or `never` (case-insensitive) must either:
  - Appear identically in the new index, OR
  - Be explicitly superseded via `[supersedes: K-<type>-<slug>]` in a new entry
- Rationale: Hard constraints are safety-critical and must never be silently dropped

**Check 3 — JSON append-only** (`verify_json_append_only`):
- Array length >= old length (no entries removed)
- All previous entries preserved byte-identically
- No duplicate `iteration` values
- Each entry must have: `iteration` (number), `task` (string), `summary` (string), `tags` (array)

**Check 4 — ID consistency** (`verify_knowledge_index`):
- No two "active" entries may share the same `memory_id`
- Every ID referenced in `supersedes` must exist as a `memory_id` somewhere in the array

### 9.5 Memory ID Format

Pattern: `K-<type>-<slug>`

Types: `constraint`, `decision`, `pattern`, `gotcha`, `unresolved`

Entry format in `knowledge-index.md`:
```
- [K-constraint-no-force-push] Must never force push to main [source: iter 3,7] [supersedes: K-constraint-old-slug]
```

### 9.6 Snapshot/Restore Mechanism

`snapshot_knowledge_indexes()` saves current files to temp files with a header encoding: line 1 is `"1"` if the original existed, `"0"` if not. `restore_knowledge_indexes()` reads this header to decide whether to recreate the file or delete it. This ensures rollback restores the exact prior state, including the case where no index existed before.

---

## 10. Agent-Orchestrated Mode (agents.sh)

### 10.1 Architecture

Two-agent architecture: a **context agent** prepares pristine context for a **coding agent**, then organizes the coding agent's output into accumulated knowledge. Optional agent passes run afterward.

**Agent call sequence per iteration**:
1. **Context prep** (pre-coding) — Reads all available artifacts, fetches library docs, assembles tailored prompt, detects stuck patterns
2. **Coding agent** — Receives the prepared prompt, implements the task, writes handoff
3. **Context post** (post-coding) — Processes handoff into knowledge index, detects failure patterns
4. **Optional passes** — Configurable agents (e.g., code review with cheaper model)

### 10.2 Generic Agent Invocation

`run_agent_iteration(prompt, schema_file, mcp_config, max_turns, model, system_prompt_file)` is the unified invocation point for all agent types. It constructs CLI args including `-p`, `--output-format json`, `--json-schema`, `--strict-mcp-config`, `--mcp-config`, `--max-turns`, and optionally `--model` and `--append-system-prompt-file`.

`parse_agent_output(response)` handles the same double-parse as `parse_handoff_output()` — extracting `.result` from the envelope and parsing it as JSON.

### 10.3 Context Preparation

**Input building** (`build_context_prep_input`):
The context agent receives a lightweight manifest with:
- Current task details (inlined — always small)
- Task metadata: retry count, skills list, libraries list, needs_docs flag
- Available context file **paths** (not contents): latest handoff, all handoffs range, knowledge index files, failure context, previous validation log, skills directory, templates
- Research requests extracted from the previous coding agent's handoff
- Human review signals and confidence level from the previous handoff
- State info: iteration, mode, plan file
- Output file path for the prepared prompt

**Critical design**: The manifest contains **file pointers, not file contents**. The context agent uses its built-in Read tool and MCP tools (Context7 for library docs) to access what it needs. This keeps the input small and lets the agent exercise judgment about what to read.

**Execution** (`run_context_prep`):
1. Builds manifest via `build_context_prep_input()`
2. Loads system prompt from `context-prep-prompt.md`
3. Removes stale `prepared-prompt.md` (so we can detect if the agent wrote a new one)
4. Invokes agent via `run_agent_iteration()`
5. Parses directive JSON from response
6. Verifies `prepared-prompt.md` exists and is >= 50 bytes
7. Returns directive JSON

**Directives** (context prep schema output):
| Action | Meaning | Orchestrator Response |
|--------|---------|----------------------|
| `proceed` | Prompt ready, run coding | Continue to coding phase |
| `skip` | Task should be skipped | Set status "skipped", continue loop |
| `request_human_review` | Human judgment needed | Pause orchestrator |
| `research` | More research needed | Task stays pending, next iteration |

**Stuck detection**: The context agent analyzes retry counts and consecutive handoff narratives. If stuck, it sets `stuck_detection.is_stuck = true` with evidence and suggested action. The orchestrator emits a `stuck_detected` event.

### 10.4 Context Post-Processing

**Input building** (`build_context_post_input`):
Manifest includes: iteration, task ID, validation result ("passed"/"failed"), handoff file path, validation log path, current knowledge index file paths, recent handoffs (last 5) for pattern detection, and verification rules reference.

**Execution** (`run_context_post`):
1. Builds manifest
2. Snapshots existing knowledge index for rollback (reuses compaction.sh snapshot machinery)
3. Invokes context agent
4. Verifies knowledge index integrity via `verify_knowledge_indexes()`
5. Rolls back if verification fails
6. Resets compaction counters on success
7. Parses and returns directive

**Post-processing directives**:
| Action | Meaning |
|--------|---------|
| `proceed` | Continue normally |
| `skip_task` | Task should be skipped |
| `modify_plan` | Plan needs adjustment (with `plan_suggestions`) |
| `request_human_review` | Situation needs human judgment |
| `increase_retries` | Task needs more attempts |

Post-processing directives are **advisory** — logged and visible to the next context prep pass via the knowledge index and event stream, but they don't break the main loop (except `request_human_review` which is logged as a warning).

### 10.5 Agent Pass Framework

Configurable passes defined in `agents.json`:
```json
{
  "passes": [
    {
      "name": "review",
      "enabled": false,
      "model": "haiku",
      "trigger": "on_success",
      "max_turns": 5,
      "prompt_template": "review-agent-prompt.md",
      "schema": "review-agent-schema.json",
      "mcp_config": "mcp-coding.json",
      "read_only": true
    }
  ]
}
```

**Trigger types**:
| Trigger | Fires When |
|---------|-----------|
| `always` | Every iteration |
| `on_success` | Validation passed |
| `on_failure` | Validation failed |
| `periodic:N` | Every N iterations (`iteration % N == 0`) |

**Key invariant**: Passes are NON-FATAL. Failures are logged but never block the main loop. They're advisory only.

`run_agent_passes()` iterates over enabled passes matching the current trigger context, invokes each via `run_agent_iteration()`, and collects results.

---

## 11. Git Operations (git-ops.sh)

### 11.1 Transactional Semantics

Every iteration is bracketed by checkpoint/commit-or-rollback. This guarantees the repo is never left in a half-modified state:

```
create_checkpoint()  →  SHA stored in local var
     │
     ▼
coding cycle runs, modifies working tree
     │
     ▼
validation runs
     │
     ├── PASS: commit_iteration()  →  git add -A && git commit
     │
     └── FAIL: rollback_to_checkpoint()  →  git reset --hard SHA && git clean -fd
```

### 11.2 Functions

**`create_checkpoint()`**: Captures `git rev-parse HEAD` as the rollback target. Outputs the 40-char SHA to stdout.

**`rollback_to_checkpoint(sha)`**: Runs `git reset --hard $sha` then `git clean -fd --exclude=.ralph/`. The `--exclude=.ralph/` is critical — it preserves all state files (handoffs, logs, control, knowledge index) so the orchestrator can continue operating after a failed iteration.

**`commit_iteration(iteration, task_id, message)`**: Runs `git add -A` then `git commit -m "${RALPH_COMMIT_PREFIX:-ralph}[${iteration}]: ${task_id} — ${message}"`. The commit message format is structured for parsing by progress tooling.

**`ensure_clean_state()`**: Auto-commits dirty working tree at startup with message `"ralph: auto-commit before orchestration start"`. Called once before the main loop.

### 11.3 Invariants

- After every iteration, the repo is either committed (success) or rolled back to checkpoint (failure). No partial states persist.
- `.ralph/` directory is NEVER cleaned by rollback.
- Iteration commits are local, linear commits. No rebase, merge, or conflict resolution.
- Conflict handling is delegated to higher-level orchestration/user workflow.

---

## 12. Plan Operations (plan-ops.sh)

### 12.1 Task Selection

`get_next_task(plan_file)` implements dependency-aware selection:
1. Filter to tasks with `status == "pending"`
2. For each pending task, check if ALL `depends_on` IDs resolve to tasks with `status == "done"`
3. Return the first runnable task in array order
4. Return empty if nothing is runnable

Selection is deterministic: repeated calls without plan mutation return the same task.

### 12.2 Status Transitions

`set_task_status(plan_file, task_id, new_status)` rewrites plan.json via temp-file-then-rename. Valid transitions:
- `pending` → `in_progress` (selected for iteration)
- `in_progress` → `done` (validation passed)
- `in_progress` → `failed` (max retries exceeded)
- `pending` or `in_progress` → `skipped` (operator skip or context agent directive)
- `in_progress` → `pending` (validation failed, will retry)

### 12.3 Plan Amendments

`apply_amendments(plan_file, handoff_file, current_task_id)` reads `.plan_amendments[]` from the handoff and applies add/modify/remove operations:

**Safety guardrails**:
- **Max 3 amendments per iteration** — Entire batch rejected if exceeded
- **Cannot modify current task's status** — Prevents self-modification
- **Cannot remove "done" tasks** — Preserves completed work
- **Backup created** — `plan.json.bak` before any mutation
- **Audit trail** — All accept/reject events logged to `.ralph/logs/amendments.log`

**Operations**:
- `add`: Requires id, title, description. Defaults provided for optional fields (status: pending, order: 999, skills: [], etc.). Can insert after a specific task ID or append to end.
- `modify`: Merges changes object into existing task. Cannot change current task's status.
- `remove`: Drops task unless it has status "done".

Amendments are applied sequentially within a batch — each amendment observes prior mutations. Individual invalid amendments are skipped; processing continues for remaining items.

### 12.4 Completion Checks

`is_plan_complete()`: Returns 0 if ALL tasks have status "done" or "skipped".

`count_remaining_tasks()`: Returns count of tasks with status "pending" or "failed" (excludes "skipped").

---

## 13. Validation (validation.sh)

### 13.1 Command Classification

`classify_command(cmd)` tags each command:
- **"lint"**: Commands matching `shellcheck|lint|eslint|flake8|pylint|stylelint`
- **"test"**: Commands matching `bats|test|pytest|jest|cargo test|mocha|rspec`
- **"test" (default)**: Unknown commands default to "test" (fail-safe — they block progress)

### 13.2 Validation Execution

`run_validation(iteration)`:
1. Iterates through `RALPH_VALIDATION_COMMANDS` array
2. Runs each command via `eval` (captures merged stdout+stderr)
3. Records exit code, output, type classification, and pass/fail for each
4. Applies strategy via `evaluate_results()`
5. Writes full results to `.ralph/logs/validation/iter-N.json`
6. Returns 0 (pass) or 1 (fail)

### 13.3 Strategies

| Strategy | Test Commands | Lint Commands |
|----------|--------------|---------------|
| `strict` (default) | Must pass | Must pass |
| `lenient` | Must pass | Failures tolerated |
| `tests_only` | Must pass | Completely ignored |

If no validation commands are configured, the gate auto-passes with a warning log.

### 13.4 Failure Context Generation

`generate_failure_context(result_file)`:
- Reads the validation result JSON
- Filters to failed checks
- For each: extracts command name and truncates output to 500 characters
- Formats as markdown under `### Validation Failures` header
- This is saved to `.ralph/context/failure-context.md` and injected into the next retry prompt's `## Failure Context` section

---

## 14. Telemetry and Control (telemetry.sh)

### 14.1 Event Stream

`emit_event(type, message, metadata)` appends one JSONL line to `.ralph/logs/events.jsonl`:
```json
{"timestamp":"2024-01-15T10:30:00Z","event":"iteration_start","message":"Starting iteration 5","metadata":{"iteration":5,"task_id":"T-003"}}
```

Event types emitted across all modules:
| Event Type | Emitted By | When |
|-----------|-----------|------|
| `orchestrator_start` | ralph.sh | Startup |
| `orchestrator_end` | ralph.sh | Shutdown |
| `iteration_start` | ralph.sh | Each iteration begins |
| `iteration_end` | ralph.sh | Each iteration completes |
| `validation_pass` | ralph.sh | Validation succeeds |
| `validation_fail` | ralph.sh | Validation fails |
| `pause` | telemetry.sh | Operator pause command |
| `resume` | telemetry.sh | Operator resume command |
| `note` | telemetry.sh | Operator inject-note |
| `skip_task` | telemetry.sh | Operator skip-task |
| `stuck_detected` | agents.sh | Context agent detects stuck pattern |
| `failure_pattern` | agents.sh | Context agent detects failure pattern |
| `human_review_requested` | ralph.sh | Coding agent signals human review needed |
| `agent_pass` | agents.sh | Agent pass completes |

### 14.2 Operator Control Plane

File-backed polling model:
1. Dashboard sends POST to `serve.py`
2. `serve.py` appends command to `.ralph/control/commands.json` `pending[]` array
3. Orchestrator calls `check_and_handle_commands()` at the top of each loop iteration
4. `process_control_commands()` reads, executes, and clears pending commands

**Command types**:
| Command | Effect |
|---------|--------|
| `pause` | Sets `RALPH_PAUSED=true`, blocks in polling loop |
| `resume` | Sets `RALPH_PAUSED=false`, unblocks |
| `inject-note` | Emits a `note` event with the operator's text |
| `skip-task` | Sets task status to "skipped" via `set_task_status()` |

**Pause behavior**: `wait_while_paused()` blocks in a `sleep $RALPH_PAUSE_POLL_SECONDS` (default 5s) polling loop, checking for a `resume` command each cycle.

**Delivery semantics**: At-least-once best effort. Commands may be replayed if a crash happens after execution but before clearing. Unknown commands are logged and ignored (non-fatal). Stale commands (e.g., resume while not paused) are treated as idempotent state-set operations.

---

## 15. Progress Logging (progress-log.sh)

### 15.1 Dual-Format Output

After each successful iteration, `append_progress_entry()` produces:

**`.ralph/progress-log.md`** — Human/LLM-readable:
- Header with plan name
- Summary table (Task | Status | Summary) rebuilt from plan.json each time
- Per-iteration `###` entries with: summary, files changed (table), tests added, design decisions, constraints, deviations, bugs

**`.ralph/progress-log.json`** — Machine-readable:
- `generated_at` timestamp
- `plan_summary`: `{total_tasks, completed, pending, failed, skipped}` computed from plan.json
- `entries[]`: Per-iteration objects with task_id, iteration, timestamp, summary, files_changed, tests_added, design_decisions, constraints, deviations, bugs, fully_complete

### 15.2 Update Semantics

- JSON: Deduplicates by `(task_id, iteration)`, refreshes `generated_at`, recomputes `plan_summary` from current plan.json
- Markdown: Fully regenerated — summary table always reflects latest task statuses, then existing entries + new entry preserved in order
- Conditional section emission — omits empty arrays (no "Deviations:" section if deviations is empty)

---

## 16. Dashboard and Server

### 16.1 serve.py

A Python HTTP server extending `SimpleHTTPRequestHandler`:
- **Static files**: Serves everything from project root, including `.ralph/dashboard.html`, `.ralph/state.json`, `plan.json`, `.ralph/handoffs/*.json`, `.ralph/logs/events.jsonl`, `.ralph/progress-log.json`
- **POST /api/command**: Appends command to `commands.json` pending array via `enqueue_command()`
- **POST /api/settings**: Updates whitelisted settings in `ralph.conf` via regex line replacement

**Whitelisted settings** (only these can be changed from dashboard):
`RALPH_VALIDATION_STRATEGY`, `RALPH_COMPACTION_INTERVAL`, `RALPH_COMPACTION_THRESHOLD_BYTES`, `RALPH_DEFAULT_MAX_TURNS`, `RALPH_MIN_DELAY_SECONDS`, `RALPH_MODE`

**Sanitization**: Setting values must match `^[a-zA-Z0-9_\-]+$` (prevents shell injection). Writes are atomic (temp-file + `os.replace()`).

### 16.2 dashboard.html

Single-page vanilla JS + Tailwind CSS dashboard. Polls the server every 3s for state updates. Features: real-time iteration status, task progress, event timeline, operator controls (pause/resume/skip/inject-note), settings panel.

---

## 17. State Files

### 17.1 state.json

Runtime state persisted across iterations:
```json
{
  "current_iteration": 5,
  "last_task_id": "T-003",
  "status": "running",
  "mode": "handoff-only",
  "started_at": "2024-01-15T10:00:00Z",
  "total_handoff_bytes_since_compaction": 15000,
  "coding_iterations_since_compaction": 3,
  "last_compaction_iteration": 2
}
```

State is read/written via `read_state(key)` / `write_state(key, value)`. Writes use temp-file-then-rename for atomicity. The `write_state` jq expression auto-coerces value types (number, bool, null, string).

### 17.2 plan.json

Task plan at project root. Structure:
```json
{
  "tasks": [
    {
      "id": "T-001",
      "title": "Task title",
      "description": "Full description",
      "status": "pending",
      "order": 1,
      "skills": ["bash-conventions", "testing-bats"],
      "needs_docs": false,
      "libraries": [],
      "acceptance_criteria": ["Tests pass", "No regressions"],
      "depends_on": [],
      "max_turns": 20,
      "retry_count": 0,
      "max_retries": 2
    }
  ]
}
```

### 17.3 commands.json

Operator control queue:
```json
{
  "pending": [
    {"command": "pause"},
    {"command": "inject-note", "note": "Check auth module"},
    {"command": "skip-task", "task_id": "T-005"}
  ]
}
```

---

## 18. Configuration Reference

| Variable | Default | Module | Purpose |
|----------|---------|--------|---------|
| `RALPH_MAX_ITERATIONS` | 50 | ralph.sh | Max iterations before forced stop |
| `RALPH_PLAN_FILE` | `plan.json` | ralph.sh | Path to task plan |
| `RALPH_MODE` | `handoff-only` | ralph.sh | Operating mode |
| `RALPH_VALIDATION_STRATEGY` | `strict` | validation.sh | Validation strictness |
| `RALPH_VALIDATION_COMMANDS` | `("bats tests/" "shellcheck ...")` | validation.sh | Commands to run |
| `RALPH_CONTEXT_BUDGET_TOKENS` | 8000 | context.sh | Token budget (handoff-only) |
| `RALPH_CONTEXT_BUDGET_TOKENS_HPI` | 16000 | context.sh | Token budget (h+i mode) |
| `RALPH_COMPACTION_INTERVAL` | 5 | compaction.sh | Iterations between compactions |
| `RALPH_COMPACTION_THRESHOLD_BYTES` | 32000 | compaction.sh | Byte threshold for compaction |
| `RALPH_COMPACTION_MAX_TURNS` | 10 | cli-ops.sh | Max turns for indexer |
| `RALPH_NOVELTY_OVERLAP_THRESHOLD` | 0.25 | compaction.sh | Novelty trigger threshold |
| `RALPH_NOVELTY_RECENT_HANDOFFS` | 3 | compaction.sh | Handoffs for novelty calc |
| `RALPH_MIN_DELAY_SECONDS` | 30 | ralph.sh | Rate limit delay |
| `RALPH_SKIP_PERMISSIONS` | `true` | cli-ops.sh, agents.sh | Skip Claude permissions |
| `RALPH_MODEL` | `""` (default) | ralph.sh | Model override |
| `RALPH_FALLBACK_MODEL` | `sonnet` | ralph.sh | Fallback model |
| `RALPH_AUTO_COMMIT` | `true` | ralph.sh | Auto-commit behavior |
| `RALPH_COMMIT_PREFIX` | `ralph` | git-ops.sh | Commit message prefix |
| `RALPH_CONTEXT_AGENT_MODEL` | `""` | agents.sh | Model override for context agent |
| `RALPH_AGENT_PASSES_ENABLED` | `true` | agents.sh | Enable/disable optional passes |
| `RALPH_LOG_LEVEL` | `info` | ralph.sh | Log verbosity |
| `RALPH_LOG_FILE` | `.ralph/logs/ralph.log` | ralph.sh | Log file path |
| `RALPH_PAUSE_POLL_SECONDS` | 5 | telemetry.sh | Pause polling interval |

---

## 19. Retry and Error Handling

### 19.1 Retry Flow

When a coding cycle fails or validation fails:
1. `rollback_to_checkpoint(sha)` restores the repo to pre-iteration state
2. `increment_retry_count(plan_file, task_id)` bumps `retry_count` in plan.json
3. If `retry_count >= max_retries` (default 2): task marked `"failed"`
4. Otherwise: task stays `"pending"`, will be re-selected next iteration
5. If validation failed: `generate_failure_context()` creates failure context saved to `.ralph/context/failure-context.md`
6. Next iteration: failure context injected into `## Failure Context` section of the prompt
7. After successful handoff parse: failure context file is deleted (deferred deletion prevents loss if cycle fails mid-flight)

### 19.2 Agent-Orchestrated Directives on Failure

In agent-orchestrated mode, coding cycle failure may include a directive from the context agent (communicated via stderr):
- `DIRECTIVE:skip` → Task marked "skipped", loop continues
- `DIRECTIVE:request_human_review` → Task reset to "pending", orchestrator paused
- `DIRECTIVE:research` → Task stays "pending", loop continues (context agent researches next iteration)

### 19.3 Graceful Degradation

All cross-module function calls are guarded with `declare -f` checks:
```bash
if declare -f emit_event >/dev/null 2>&1; then
    emit_event "iteration_start" "..."
fi
```

This means:
- Missing modules don't crash the orchestrator
- Individual subsystems (telemetry, progress logging, control plane) degrade independently
- Tests can source individual modules without loading the full system

### 19.4 Non-Fatal Operations

Several operations are explicitly non-fatal:
- Progress log updates: failure logged, iteration continues
- Amendment application: individual amendments rejected, batch continues
- Agent passes: failures logged, main loop continues
- Context post-processing: failure logged, main loop continues
- Knowledge index verification failure: changes rolled back, orchestrator proceeds

---

## 20. Skills System

### 20.1 Skill Files

Skills are markdown convention files stored in `.ralph/skills/`:

| File | Content |
|------|---------|
| `bash-conventions.md` | Shell scripting standards |
| `git-workflow.md` | Git commit conventions |
| `jq-patterns.md` | JSON processing patterns |
| `mcp-config.md` | MCP server configuration |
| `testing-bats.md` | bats-core testing conventions |

### 20.2 Skill Loading

Each task in plan.json can specify a `skills[]` array (e.g., `["bash-conventions", "testing-bats"]`). `load_skills(task_json, skills_dir)` concatenates the matching `.md` files. Missing skills are logged as warnings but non-fatal.

In non-agent modes: skills content is passed to `build_coding_prompt_v2()` for the `## Skills` section. A temp file is also created via `prepare_skills_file()` for `--append-system-prompt-file`.

In agent-orchestrated mode: the context agent reads skill files directly and incorporates them into the prepared prompt.

---

## 21. Templates

### 21.1 Coding Agent Templates

**`coding-prompt-footer.md`**: Output instructions for the coding agent. Tells it to write a handoff document with summary and freeform fields, match the JSON schema, and cover: what was done, surprises, fragile/incomplete areas, recommendations, key technical details.

**`coding-prompt.md`**: Fallback output instructions if footer template is missing.

**`first-iteration.md`**: Injected on iteration 1 when no prior handoffs exist. Tells the coding agent it's starting from a clean slate, establishes the importance of thorough handoff documentation, and reminds it to document every decision since it's seeding all future context.

### 21.2 Context Agent Templates

**`context-prep-prompt.md`**: System prompt for the context preparation agent. Defines its role (research, not coding), its MCP tools (Context7 for library docs), the exact section headers it must use in the prepared prompt, context assembly principles (clarity over brevity, pre-digest everything, synthesize don't dump), stuck detection criteria, and output directive format.

**`context-post-prompt.md`**: System prompt for the knowledge organization agent. Defines knowledge index format, memory ID conventions, verification rules it must follow, failure pattern detection criteria, coding agent signal processing, and output directive format.

### 21.3 Other Templates

**`knowledge-index-prompt.md`**: Instructions for the knowledge indexer (compaction.sh path). Defines the dual-file format (markdown categories + JSON array), entry format with memory IDs and source iterations, and verification rules.

**`memory-prompt.md`**: Template for legacy memory compaction agent (pre-knowledge-index approach).

**`review-agent-prompt.md`**: System prompt for the code review agent pass.

---

## 22. Test Suite

Framework: **bats-core**. Files in `tests/`. Each test file creates temp directories for isolation.

### 22.1 Test Files and Coverage

| Test File | Module | Key Coverage |
|-----------|--------|-------------|
| `agents.bats` | agents.sh | Context prep/post input building, directive handling, pass triggers, agent config loading, dry-run flows, handoff signal fields |
| `cli-ops.bats` | cli-ops.sh | Handoff parsing, metadata extraction, save numbering |
| `compaction.bats` | compaction.sh | Constraint supersession, constraint drop rejection, novelty thresholds, JSON append-only, verification checks |
| `context.bats` | context.sh | 7-section parsing, truncation priority order, mode-sensitive handoff retrieval, knowledge index inlining, budget-per-mode |
| `error-handling.bats` | ralph.sh | Retry/rollback resilience, interrupted-run behavior |
| `git-ops.bats` | git-ops.sh | Checkpoint creation, rollback behavior, commit format |
| `integration.bats` | ralph.sh | Full orchestrator cycles, state management, validation flow |
| `plan-ops.bats` | plan-ops.sh | Dependency resolution, amendment guardrails (max 3, no done removal), status transitions |
| `progress-log.bats` | progress-log.sh | Entry formatting, summary table generation, deduplication |
| `telemetry.bats` | telemetry.sh | Event emission, control command processing, pause/resume |
| `validation.bats` | validation.sh | Strategy evaluation, command classification, failure context generation |

### 22.2 Test Patterns

- **Temp workspace**: Each test creates `mktemp -d` workspace, tears down on exit
- **Log stubs**: `log() { true; }` silences output
- **Fixture data**: JSON handoffs, plans, and state files created inline
- **Function guards**: `declare -f` used to verify functions are defined
- **Mode parameterization**: Tests run against multiple modes to verify mode-sensitive behavior
- **Dry-run testing**: Tests use `DRY_RUN=true` to verify pipeline without CLI invocation

---

## 23. Screenshot Tooling

### 23.1 Purpose

`screenshots/capture.sh` and `screenshots/take-screenshots.mjs` produce dashboard screenshots for documentation. Uses Playwright with Chromium.

### 23.2 Key Constraints

- External CDN is unreachable — Tailwind CSS is built locally from `screenshots/tailwind.config.js` and injected via Playwright's `page.route()` intercept
- Chromium requires `--single-process --no-sandbox --disable-gpu --disable-dev-shm-usage` flags
- Mock data (12 handoffs, plan, state, events, knowledge index, progress log) is installed into live paths with `.screenshot-bak` backup/restore
- `tailwind.config.js` content path is `../.ralph/dashboard.html` (relative to `screenshots/` dir)
- Captures 6 views at 2x resolution (2880x1800)

---

## 24. Directory Structure Reference

| Path | Purpose |
|------|---------|
| `.ralph/ralph.sh` | Main orchestrator entry point |
| `.ralph/lib/*.sh` | 9 library modules (sourced by ralph.sh) |
| `.ralph/config/ralph.conf` | Runtime configuration |
| `.ralph/config/agents.json` | Agent pass configuration |
| `.ralph/config/handoff-schema.json` | Coding agent output schema |
| `.ralph/config/context-prep-schema.json` | Context prep output schema |
| `.ralph/config/context-post-schema.json` | Context post output schema |
| `.ralph/config/review-agent-schema.json` | Review agent output schema |
| `.ralph/config/memory-output-schema.json` | Legacy memory compaction schema |
| `.ralph/config/mcp-coding.json` | MCP config for coding (empty — no tools) |
| `.ralph/config/mcp-context.json` | MCP config for context agent (Context7) |
| `.ralph/config/mcp-memory.json` | MCP config for memory agent |
| `.ralph/templates/coding-prompt-footer.md` | Output instructions template |
| `.ralph/templates/coding-prompt.md` | Fallback output instructions |
| `.ralph/templates/context-prep-prompt.md` | Context prep agent system prompt |
| `.ralph/templates/context-post-prompt.md` | Context post agent system prompt |
| `.ralph/templates/first-iteration.md` | First iteration onboarding |
| `.ralph/templates/knowledge-index-prompt.md` | Knowledge indexer instructions |
| `.ralph/templates/memory-prompt.md` | Legacy memory compaction prompt |
| `.ralph/templates/review-agent-prompt.md` | Review agent system prompt |
| `.ralph/skills/*.md` | Per-task skill/convention files |
| `.ralph/handoffs/handoff-NNN.json` | Raw handoff per iteration |
| `.ralph/control/commands.json` | Dashboard→orchestrator command queue |
| `.ralph/logs/events.jsonl` | Append-only JSONL telemetry |
| `.ralph/logs/ralph.log` | Text log file |
| `.ralph/logs/validation/iter-N.json` | Per-iteration validation results |
| `.ralph/logs/amendments.log` | Plan amendment audit log |
| `.ralph/context/prepared-prompt.md` | Context agent's prepared prompt |
| `.ralph/context/failure-context.md` | Failure context for retry |
| `.ralph/context/compacted-latest.json` | Legacy compacted context |
| `.ralph/state.json` | Runtime state |
| `.ralph/knowledge-index.md` | Categorized knowledge index |
| `.ralph/knowledge-index.json` | Iteration-keyed JSON index |
| `.ralph/progress-log.md` | Human-readable progress log |
| `.ralph/progress-log.json` | Machine-readable progress log |
| `.ralph/dashboard.html` | Single-page operator dashboard |
| `.ralph/serve.py` | HTTP server for dashboard |
| `plan.json` | Task plan (project root) |
| `tests/*.bats` | bats-core test suite |
| `tests/test_helper/common.sh` | Shared test helper |
| `screenshots/` | Dashboard screenshot tooling |
| `CLAUDE.md` | LLM agent project conventions |

---

## 25. Critical Invariants Summary

These invariants must hold for the system to function correctly:

1. **Git transactionality**: After every iteration, repo is either committed (success) or rolled back to checkpoint (failure). No partial states persist.
2. **`.ralph/` preservation**: The `.ralph/` directory is NEVER cleaned by rollback (`--exclude=.ralph/`).
3. **Section header literals**: The 7 section headers in `build_coding_prompt_v2()` must exactly match the awk patterns in `truncate_to_budget()`. Renaming any header silently breaks truncation.
4. **Mode parameter passing**: `build_coding_prompt_v2()` must pass `$mode` variable, not a hardcoded string. Tests verify this.
5. **Hard constraint preservation**: `must`/`must not`/`never` lines under `## Constraints` in the knowledge index are never silently dropped — they must be explicitly superseded.
6. **JSON append-only**: `knowledge-index.json` array length >= previous length. No entries removed. No duplicate iterations.
7. **Memory ID uniqueness**: No two active entries share the same memory_id. All supersedes targets must exist.
8. **Amendment limits**: Max 3 amendments per iteration. Cannot modify current task status. Cannot remove "done" tasks.
9. **Dependency resolution**: Tasks only become runnable when all `depends_on` IDs resolve to "done" status.
10. **Handoff minimum**: The `freeform` field must be at least 50 characters.
11. **Failure context lifecycle**: Failure context is deleted only after successful handoff parse (deferred deletion).
12. **Coding agent isolation**: The coding agent has NO MCP tools. Everything it needs must be in the prompt.
13. **Pass non-fatality**: Agent passes never block the main loop regardless of outcome.
14. **Atomic file writes**: All JSON/config file mutations use temp-file-then-rename for consistency with concurrent readers.

---

## 26. Function Index

### ralph.sh
| Function | Signature | Returns | Purpose |
|----------|-----------|---------|---------|
| `log` | `(level, message)` | void | Central logging to file + stderr |
| `parse_args` | `("$@")` | void | CLI argument parsing |
| `load_config` | `()` | void | Source ralph.conf |
| `read_state` | `(key)` | string | Read from state.json |
| `write_state` | `(key, value)` | void | Write to state.json atomically |
| `source_libs` | `()` | void | Source all .ralph/lib/*.sh |
| `prepare_skills_file` | `(task_json)` | filepath | Create temp file with skills content |
| `build_memory_prompt` | `(compaction_input, task_json?)` | string | Legacy memory agent prompt |
| `run_compaction_cycle` | `(task_json?)` | 0/1 | Legacy compaction (backward compat) |
| `run_agent_coding_cycle` | `(task_json, iteration)` | handoff_path | Agent-orchestrated coding cycle |
| `run_coding_cycle` | `(task_json, iteration)` | handoff_path | Standard coding cycle |
| `increment_retry_count` | `(plan_file, task_id)` | void | Bump retry_count in plan |
| `shutdown_handler` | `()` | exit 130 | SIGINT/SIGTERM handler |
| `main` | `("$@")` | void | Orchestrator entry point |

### agents.sh
| Function | Signature | Returns | Purpose |
|----------|-----------|---------|---------|
| `run_agent_iteration` | `(prompt, schema, mcp, turns, model?, sysprompt?)` | JSON | Generic agent invocation |
| `parse_agent_output` | `(response)` | JSON | Double-parse agent response |
| `build_context_prep_input` | `(task_json, iteration, mode)` | string | Prep agent manifest |
| `run_context_prep` | `(task_json, iteration, mode)` | directive JSON | Run context preparation |
| `read_prepared_prompt` | `()` | string | Read prepared-prompt.md |
| `build_context_post_input` | `(handoff, iteration, task_id, result)` | string | Post agent manifest |
| `run_context_post` | `(handoff, iteration, task_id, result)` | directive JSON | Run knowledge organization |
| `handle_prep_directives` | `(directive_json)` | action string | Process prep directives |
| `handle_post_directives` | `(directive_json)` | action string | Process post directives |
| `load_agent_passes_config` | `()` | JSON array | Load enabled passes |
| `build_pass_input` | `(name, handoff, iteration, task_id)` | string | Pass manifest |
| `check_pass_trigger` | `(trigger, result, iteration)` | 0/1 | Check trigger condition |
| `run_agent_passes` | `(handoff, iteration, task_id, result)` | JSON array | Run all matching passes |

### cli-ops.sh
| Function | Signature | Returns | Purpose |
|----------|-----------|---------|---------|
| `run_coding_iteration` | `(prompt, task_json, skills_file?)` | JSON envelope | Invoke Claude for coding |
| `run_memory_iteration` | `(prompt)` | JSON envelope | Invoke Claude for memory |
| `parse_handoff_output` | `(response)` | handoff JSON | Double-parse response |
| `save_handoff` | `(json, iteration)` | filepath | Persist handoff to disk |
| `extract_response_metadata` | `(response)` | JSON | Extract cost/duration/turns |

### context.sh
| Function | Signature | Returns | Purpose |
|----------|-----------|---------|---------|
| `get_budget_for_mode` | `(mode)` | number | Token budget for mode |
| `estimate_tokens` | `(text)` | number | Approximate token count |
| `truncate_to_budget` | `(content, budget?)` | string | Section-aware truncation |
| `load_skills` | `(task_json, skills_dir?)` | string | Load skill file contents |
| `get_prev_handoff_summary` | `(handoffs_dir?)` | JSON | Legacy L2 summary |
| `get_prev_handoff_for_mode` | `(handoffs_dir?, mode?)` | string | Mode-sensitive handoff |
| `get_earlier_l1_summaries` | `(handoffs_dir?)` | string | Historical L1 summaries |
| `format_compacted_context` | `(compacted_file)` | string | Legacy compacted context |
| `retrieve_relevant_knowledge` | `(task_json, index?, max?)` | string | Keyword knowledge lookup |
| `build_coding_prompt_v2` | `(task, mode, skills, failure, first?)` | string | 7-section prompt builder |
| `build_coding_prompt` | `(task, ctx, prev, skills, fail, l1)` | string | Legacy v1 prompt builder |

### compaction.sh
| Function | Signature | Returns | Purpose |
|----------|-----------|---------|---------|
| `tokenize_terms` | `(text)` | terms | Tokenize for novelty |
| `build_task_term_signature` | `(task_json)` | terms | Task term signature |
| `build_recent_handoff_term_signature` | `(dir, limit)` | terms | Handoff term signature |
| `calculate_term_overlap` | `(task_terms, handoff_terms)` | decimal | Overlap ratio |
| `check_compaction_trigger` | `(state_file, task_json?)` | 0/1 | Should indexer run? |
| `extract_l1` | `(handoff_file)` | string | One-line summary |
| `extract_l2` | `(handoff_file)` | JSON | Key decisions object |
| `extract_l3` | `(handoff_file)` | filepath | File path reference |
| `build_compaction_input` | `(handoffs_dir?, state_file?)` | string | L2 data since compaction |
| `build_indexer_prompt` | `(compaction_input)` | string | Indexer prompt |
| `run_knowledge_indexer` | `(task_json?)` | 0/1 | Full indexer cycle |
| `snapshot_knowledge_indexes` | `(md, json, bak_md, bak_json)` | void | Save for rollback |
| `restore_knowledge_indexes` | `(md, json, bak_md, bak_json)` | void | Restore from backup |
| `verify_knowledge_indexes` | `(md, json, bak_md, bak_json)` | 0/1 | Run all 4 checks |
| `verify_knowledge_index_header` | `(md)` | 0/1 | Check header format |
| `verify_hard_constraints_preserved` | `(md, bak_md)` | 0/1 | Check constraints |
| `verify_json_append_only` | `(json, bak_json)` | 0/1 | Check append-only |
| `verify_knowledge_index` | `(json?)` | 0/1 | Check ID consistency |
| `update_compaction_state` | `(state_file?)` | void | Reset counters |

### git-ops.sh
| Function | Signature | Returns | Purpose |
|----------|-----------|---------|---------|
| `create_checkpoint` | `()` | SHA string | Capture HEAD for rollback |
| `rollback_to_checkpoint` | `(sha)` | void | Hard reset + clean |
| `commit_iteration` | `(iteration, task_id, message)` | void | Stage and commit |
| `ensure_clean_state` | `()` | void | Auto-commit dirty tree |

### plan-ops.sh
| Function | Signature | Returns | Purpose |
|----------|-----------|---------|---------|
| `get_next_task` | `(plan_file?)` | JSON | Dependency-aware selection |
| `set_task_status` | `(plan_file, task_id, status)` | void | Update task status |
| `get_task_by_id` | `(plan_file, task_id)` | JSON | Lookup task by ID |
| `apply_amendments` | `(plan_file, handoff, current_task?)` | 0/1 | Apply plan mutations |
| `is_plan_complete` | `(plan_file?)` | 0/1 | All tasks done/skipped? |
| `count_remaining_tasks` | `(plan_file?)` | number | Pending + failed count |

### validation.sh
| Function | Signature | Returns | Purpose |
|----------|-----------|---------|---------|
| `classify_command` | `(cmd)` | "test"/"lint" | Tag command type |
| `run_validation` | `(iteration)` | 0/1 | Execute and evaluate |
| `evaluate_results` | `(checks_json, strategy)` | "true"/"false" | Apply strategy |
| `generate_failure_context` | `(result_file)` | string | Failure context markdown |

### telemetry.sh
| Function | Signature | Returns | Purpose |
|----------|-----------|---------|---------|
| `emit_event` | `(type, message, metadata?)` | void | Append JSONL event |
| `init_control_file` | `()` | void | Create commands.json |
| `read_pending_commands` | `()` | JSON array | Read command queue |
| `clear_pending_commands` | `()` | void | Reset pending array |
| `process_control_commands` | `()` | void | Execute all pending |
| `wait_while_paused` | `()` | void | Block until resume |
| `check_and_handle_commands` | `()` | void | Process + maybe pause |

### progress-log.sh
| Function | Signature | Returns | Purpose |
|----------|-----------|---------|---------|
| `init_progress_log` | `()` | void | Create log files |
| `format_progress_entry_md` | `(handoff, iteration, task_id)` | string | Markdown entry |
| `format_progress_entry_json` | `(handoff, iteration, task_id)` | JSON | JSON entry |
| `append_progress_entry` | `(handoff, iteration, task_id)` | 0/1 | Append to both logs |

---

## 27. Data Flow Diagrams

### 27.1 Handoff Data Flow

```
Coding Agent → handoff JSON → parse_handoff_output()
  │
  ├── save_handoff() → .ralph/handoffs/handoff-NNN.json
  │
  ├── append_progress_entry() → progress-log.{md,json}
  │
  ├── apply_amendments() → plan.json mutations
  │
  ├── freeform field → next iteration's ## Previous Handoff
  │
  ├── constraints + decisions → next iteration's ## Retrieved Memory
  │
  ├── request_research → next context prep's research requests
  │
  └── L2 extraction → knowledge indexer input → knowledge-index.{md,json}
```

### 27.2 Failure Context Flow

```
Validation fails
  │
  ├── run_validation() writes iter-N.json
  │
  ├── generate_failure_context() → failure-context.md
  │
  ├── rollback_to_checkpoint() → repo restored
  │
  └── Next iteration:
      ├── failure-context.md → ## Failure Context section
      └── Deleted after successful handoff parse
```

### 27.3 Knowledge Index Flow

```
Handoff files accumulated
  │
  ├── check_compaction_trigger() fires
  │     (metadata / novelty / bytes / periodic)
  │
  ├── build_compaction_input() → L2 data from recent handoffs
  │
  ├── build_indexer_prompt() → template + existing index + L2 data
  │
  ├── run_memory_iteration() → Claude writes knowledge-index.{md,json}
  │
  ├── verify_knowledge_indexes() → 4 checks
  │     ├── PASS: update_compaction_state()
  │     └── FAIL: restore_knowledge_indexes()
  │
  └── Next iteration:
      └── knowledge-index.md → inlined in ## Retrieved Project Memory
```

### 27.4 Operator Control Flow

```
Dashboard UI
  │
  ├── POST /api/command → serve.py → commands.json pending[]
  │
  ├── POST /api/settings → serve.py → ralph.conf (whitelisted)
  │
  └── GET /* → serve.py → static files (state, plan, events, etc.)

Orchestrator (each iteration top):
  │
  ├── check_and_handle_commands()
  │     ├── read_pending_commands()
  │     ├── process_control_commands()
  │     │     ├── pause → RALPH_PAUSED=true
  │     │     ├── resume → RALPH_PAUSED=false
  │     │     ├── inject-note → emit_event("note")
  │     │     └── skip-task → set_task_status("skipped")
  │     └── clear_pending_commands()
  │
  └── if paused: wait_while_paused() (poll loop)
```
