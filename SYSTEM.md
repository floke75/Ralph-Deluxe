# Ralph Deluxe — Complete System Documentation for LLM Agents

This document provides a complete, self-contained understanding of the Ralph Deluxe system. An LLM reading only this document should be able to reason about every component, data flow, invariant, edge case, and behavioral nuance without examining source code.

---

## 1. System Identity

Ralph Deluxe is a **Bash orchestrator** that drives the Claude Code CLI through structured task plans. It reads a `plan.json` containing ordered tasks with dependencies, then iterates through them one at a time: assembling a context-rich prompt, invoking Claude to implement the task, validating the output, and either committing the result or rolling back and retrying.

The core insight: each coding iteration writes a **freeform handoff narrative** that becomes the primary context for the next iteration. This is how the system maintains continuity across what are otherwise stateless LLM calls.

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

The mode is resolved in `main()` of `ralph.sh`: CLI args are parsed first, then config is loaded, then the priority chain is evaluated. The resolved mode is written to `state.json` so the dashboard and `--resume` can read it.

### 3.1 `handoff-only` (default)

Memory consists entirely of the previous iteration's freeform narrative. No knowledge index, no compaction. The simplest mode — prompt assembly is pure Bash string concatenation.

- **Memory artifact**: Previous handoff's `.freeform` field only
- **Prompt assembly**: `build_coding_prompt_v2()` in `context.sh` (Bash)
- **Token budget**: 8000 tokens (`RALPH_CONTEXT_BUDGET_TOKENS`)
- **Agent calls per iteration**: 1 (coding agent only)
- **Compaction**: None
- **Best for**: Short projects (< 10 iterations) where handoff drift isn't a concern

### 3.2 `handoff-plus-index`

Adds a persistent knowledge index that accumulates constraints, decisions, patterns, and gotchas across all iterations. The knowledge indexer runs periodically (trigger-based) to consolidate handoff data into `.ralph/knowledge-index.md` and `.ralph/knowledge-index.json`.

- **Memory artifacts**: Previous handoff narrative + structured L2 data + full knowledge index inlined in prompt
- **Prompt assembly**: `build_coding_prompt_v2()` in `context.sh` (Bash)
- **Token budget**: 16000 tokens (`RALPH_CONTEXT_BUDGET_TOKENS_HPI`) — double the base to accommodate the inlined index
- **Agent calls per iteration**: 1-2 (coding agent + optional knowledge indexer)
- **Compaction**: Trigger-based via `check_compaction_trigger()` in `compaction.sh`
- **Best for**: Medium-length projects where key decisions need to persist beyond the handoff window

### 3.3 `agent-orchestrated`

An LLM **context agent** replaces Bash prompt assembly entirely. It reads all available context (handoffs, knowledge index, failure logs, library documentation via MCP tools) and writes a tailored prompt for the coding agent. After coding, it organizes knowledge. Optional agent passes (code review, docs) can run after each iteration.

- **Memory artifacts**: LLM-curated context + knowledge index managed by context agent
- **Prompt assembly**: LLM context agent writes `.ralph/context/prepared-prompt.md`
- **Token budget**: Not Bash-enforced — the context agent uses judgment
- **Agent calls per iteration**: 2-3+ (context prep + coding + context post + optional passes)
- **Compaction**: Every iteration (context post agent handles knowledge organization)
- **Best for**: Long or complex projects where context quality is critical

---

## 4. Module Dependency Map

```
ralph.sh (main orchestrator)
  ├── sources all .ralph/lib/*.sh modules via glob
  │
  ├── agents.sh        Multi-agent orchestration (808 lines)
  │   ├── calls: compaction.sh (snapshot/verify/restore, update_compaction_state)
  │   ├── calls: telemetry.sh (emit_event, guarded)
  │   └── calls: cli-ops.sh (run_coding_iteration, parse_handoff_output)
  │
  ├── cli-ops.sh       Claude CLI invocation and response parsing (213 lines)
  │   └── calls: `claude` binary
  │
  ├── compaction.sh    Knowledge indexing, triggers, verification (656 lines)
  │   ├── calls: cli-ops.sh (run_memory_iteration)
  │   └── reads: handoffs, state.json, knowledge-index files
  │
  ├── context.sh       Prompt assembly and truncation (769 lines)
  │   └── reads: handoffs, knowledge-index.md, skills files, templates
  │
  ├── git-ops.sh       Checkpoint, rollback, commit (85 lines)
  │   └── calls: git CLI
  │
  ├── plan-ops.sh      Task selection, status, amendments (312 lines)
  │   └── reads/writes: plan.json
  │
  ├── progress-log.sh  Dual-format progress logging (420 lines)
  │   ├── calls: plan-ops.sh (get_task_by_id)
  │   └── writes: progress-log.md, progress-log.json
  │
  ├── telemetry.sh     Event stream + operator control plane (230 lines)
  │   ├── calls: plan-ops.sh (set_task_status for skip-task)
  │   └── writes: events.jsonl, reads/clears commands.json
  │
  └── validation.sh    Post-iteration test/lint gate (268 lines)
      └── writes: validation/iter-N.json

serve.py (HTTP server, 233 lines)
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

```
1. parse_args()          — capture CLI flags (--mode, --plan, --dry-run, --resume, etc.)
2. load_config()         — source ralph.conf (sets RALPH_MODE, RALPH_VALIDATION_COMMANDS, etc.)
3. Resolve MODE           — CLI flag > config > default
4. source_libs()         — glob-source all .ralph/lib/*.sh (modules read config globals at source time)
5. init_control_file()   — create .ralph/control/commands.json if absent
6. init_progress_log()   — create .ralph/progress-log.{md,json} if absent
7. emit_event("orchestrator_start") — telemetry
8. ensure_clean_state()  — auto-commit dirty working tree (so first rollback has a clean base)
```

**Critical invariant**: Modules are sourced AFTER config load so they can read config globals (like `RALPH_CONTEXT_BUDGET_TOKENS`, `RALPH_COMPACTION_INTERVAL`) at source time.

**State initialization**: Sets `current_iteration=0`, `status="running"`, `started_at`, `mode` in `state.json`. On `--resume`, reads existing iteration counter instead.

### 5.2 Iteration Lifecycle

Each iteration follows this sequence. Mode-dependent branches are marked.

```
┌─ TOP OF LOOP ──────────────────────────────────────────────────────────────┐
│                                                                            │
│  1. Check SHUTTING_DOWN flag (cooperative shutdown)                         │
│  2. check_and_handle_commands() — process operator commands (pause/skip)    │
│  3. is_plan_complete() — exit if all tasks done/skipped                     │
│  4. get_next_task() — first pending task with all depends_on satisfied      │
│     └─ empty → status="blocked", exit loop                                 │
│  5. Increment current_iteration, write to state.json                       │
│  6. emit_event("iteration_start")                                          │
│                                                                            │
│  ┌─ MODE BRANCH: Pre-task processing ──────────────────────────────────┐   │
│  │  handoff-plus-index: check_compaction_trigger() → maybe indexer     │   │
│  │  agent-orchestrated: (handled inside run_agent_coding_cycle)        │   │
│  │  handoff-only: (nothing)                                            │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                            │
│  7. set_task_status(task_id, "in_progress")                                │
│  8. create_checkpoint() — git rev-parse HEAD (SHA for rollback)            │
│                                                                            │
│  ┌─ MODE BRANCH: Coding cycle ─────────────────────────────────────────┐   │
│  │  handoff-only / handoff-plus-index:                                  │   │
│  │    run_coding_cycle() → build prompt (Bash) → claude CLI → parse    │   │
│  │  agent-orchestrated:                                                 │   │
│  │    run_agent_coding_cycle() → context prep → claude CLI → parse     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                            │
│  9. On coding cycle FAILURE:                                               │
│     ├─ Check for agent directives (skip/review/research) on stderr         │
│     ├─ rollback_to_checkpoint()                                            │
│     ├─ increment_retry_count()                                             │
│     ├─ If retries >= max_retries → set_task_status("failed")               │
│     └─ continue to next iteration                                          │
│                                                                            │
│  10. run_validation(iteration) — execute RALPH_VALIDATION_COMMANDS          │
│      ├─ PASS:                                                              │
│      │   ├─ commit_iteration() — git add -A && git commit                  │
│      │   ├─ set_task_status("done")                                        │
│      │   ├─ append_progress_entry() — update progress logs                 │
│      │   └─ apply_amendments() — process plan_amendments from handoff      │
│      └─ FAIL:                                                              │
│          ├─ rollback_to_checkpoint()                                       │
│          ├─ increment_retry_count()                                        │
│          ├─ generate_failure_context() → .ralph/context/failure-context.md  │
│          └─ If retries >= max_retries → set_task_status("failed")          │
│                                                                            │
│  ┌─ MODE BRANCH: Post-iteration (agent-orchestrated only) ────────────┐   │
│  │  11. run_context_post() — knowledge organization                    │   │
│  │  12. run_agent_passes() — optional passes (code review, etc.)       │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                            │
│  13. Rate limit delay (RALPH_MIN_DELAY_SECONDS, default 30s)               │
│                                                                            │
└─ BOTTOM OF LOOP ───────────────────────────────────────────────────────────┘
```

### 5.3 Terminal States

| Condition | state.json `status` | Exit behavior |
|-----------|---------------------|---------------|
| All tasks done/skipped | `complete` | Normal exit |
| No runnable tasks (blocked deps) | `blocked` | Normal exit |
| `current_iteration >= MAX_ITERATIONS` | `max_iterations_reached` | Normal exit |
| SIGINT/SIGTERM received | `interrupted` | Exit 130 |
| Operator pause + human review | `paused` | Break from loop |

### 5.4 Signal Handling

`shutdown_handler()` catches SIGINT/SIGTERM:
1. Sets `SHUTTING_DOWN=true` (reentrant guard prevents double cleanup)
2. Emits `orchestrator_end` event (guarded with `declare -f`)
3. Sets state to `"interrupted"`
4. Exits with code 130

The main loop checks `SHUTTING_DOWN` at the top of each iteration for cooperative shutdown.

### 5.5 Dry Run Mode

When `--dry-run` is active, the coding cycle runs but Claude CLI returns a mock response. This exercises the full pipeline (prompt assembly, handoff parsing, progress logging, plan mutation) without API calls. Even compaction triggers and knowledge indexing run in dry-run mode for pipeline verification.

---

## 6. Prompt Assembly (context.sh)

### 6.1 The 7-Section Prompt

`build_coding_prompt_v2(task_json, mode, skills_content, failure_context, first_iteration_context)` assembles a markdown prompt with 7 named sections. The 5th parameter is optional — on iteration 1, ralph.sh passes `first-iteration.md` content; it's injected into `## Previous Handoff` when no prior handoffs exist.

**Critical invariant**: Section headers must be EXACTLY `## Name` as listed below. The `truncate_to_budget()` awk parser matches these literal strings. Renaming any header silently breaks truncation.

| # | Section Header | Source | Present When | Truncation Priority (1=first removed) |
|---|---------------|--------|-------------|---------------------------------------|
| 1 | `## Current Task` | plan.json task | Always | 7 (last resort — hard truncate) |
| 2 | `## Failure Context` | validation output | Retry only | 6 |
| 3 | `## Retrieved Memory` | Latest handoff constraints + decisions | Always | 5 |
| 4 | `## Previous Handoff` | `get_prev_handoff_for_mode()` or first-iteration.md | Always (content varies) | 3 |
| 5 | `## Retrieved Project Memory` | Full `.ralph/knowledge-index.md` inlined | h+i mode + index exists | 4 |
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
- Unknown mode: Logs warning, falls back to handoff-only behavior.
- **Critical invariant**: `build_coding_prompt_v2()` must pass the `$mode` variable, not a hardcoded string. Tests verify this.

**Section 5 — Retrieved Project Memory**: Only present in `handoff-plus-index` mode when `knowledge-index.md` exists. The full file contents are inlined (typically 20-40 lines / ~1500-2500 tokens). This guarantees all hard constraints are present without keyword matching. If the index grows too large, truncation removes this entire section, and the coding agent can still `Read` the file directly.

**Section 6 — Skills**: Task-specific convention files from `.ralph/skills/`. Loaded by `load_skills()` which reads each file named in the task's `skills[]` array from the skills directory. Missing skill files are logged as warnings but non-fatal.

**Section 7 — Output Instructions**: Loaded from `.ralph/templates/coding-prompt-footer.md`. Falls back to `coding-prompt.md`, then to a hardcoded inline template. Instructs the coding agent on handoff document format.

### 6.3 Truncation System

`truncate_to_budget(content, budget_tokens)` enforces token limits via section-aware truncation:

1. **Budget check**: If content fits within `budget_tokens * 4` characters, pass through unchanged. The `chars / 4` heuristic approximates tokens.
2. **Section parsing**: An awk pass splits content into 7 named sections by matching exact `## Header` lines.
3. **Iterative trimming**: Sections are removed entirely (not partially) in priority order until within budget: Skills → Output Instructions → Previous Handoff → Retrieved Project Memory → Retrieved Memory → Failure Context → Current Task (hard truncate as last resort).
4. **Metadata emission**: Emits `[[TRUNCATION_METADATA]]` JSON to stderr with: `truncated_sections` (array of removed section names), `max_chars`, `original_chars`. Not included in the prompt sent to Claude.
5. **Defensive fallback**: If awk parsing fails to find `## Current Task`, falls back to raw `content[:max_chars]` truncation with a `parser-fallback` metadata tag.

### 6.4 Token Budgets

| Mode | Budget Variable | Default | Rationale |
|------|----------------|---------|-----------|
| handoff-only | `RALPH_CONTEXT_BUDGET_TOKENS` | 8000 | No knowledge index, minimal context |
| handoff-plus-index | `RALPH_CONTEXT_BUDGET_TOKENS_HPI` | 16000 | Accommodates full inlined knowledge index |
| agent-orchestrated | N/A | Context agent decides | No bash truncation; agent manages budget |

### 6.5 Knowledge Retrieval (Legacy)

`retrieve_relevant_knowledge(task_json, index_file, max_lines)` performs keyword-based lookup against `knowledge-index.md`:
1. Extracts search terms from task ID, title, description, and libraries
2. Searches the index file via awk, matching terms against lines
3. Tags matches by category heading
4. Sorts by category priority: Constraints (1) > Architectural Decisions (2) > Unresolved (3) > Gotchas (4) > Patterns (5)
5. Returns max 12 lines

**Note**: This function is retained for backward compatibility but is **no longer called** by `build_coding_prompt_v2()`, which now inlines the full knowledge index instead.

### 6.6 Key Functions

| Function | Signature | Purpose |
|----------|-----------|---------|
| `build_coding_prompt_v2` | `(task_json, mode, skills_content, failure_context, first_iteration_context)` | Primary prompt builder |
| `truncate_to_budget` | `(content, budget_tokens)` | Section-aware truncation |
| `get_prev_handoff_for_mode` | `(handoffs_dir, mode)` | Mode-sensitive handoff retrieval |
| `get_budget_for_mode` | `(mode)` | Returns 8000 or 16000 |
| `estimate_tokens` | `(text)` | `chars / 4` heuristic |
| `load_skills` | `(task_json, skills_dir)` | Reads skill `.md` files for task's `skills[]` |
| `retrieve_relevant_knowledge` | `(task_json, index_file, max_lines)` | Legacy keyword matching (retained, unused) |
| `_latest_handoff_file` | `(handoffs_dir)` | Resolves latest handoff via find + sort -V |

---

## 7. Claude CLI Interaction (cli-ops.sh)

### 7.1 Coding Iteration Invocation

`run_coding_iteration(prompt, task_json, skills_file)` invokes the `claude` CLI:

```bash
claude -p \
  --output-format json \
  --json-schema "$(cat .ralph/config/handoff-schema.json)" \
  --strict-mcp-config \
  --mcp-config .ralph/config/mcp-coding.json \
  --max-turns 200 \
  --dangerously-skip-permissions \           # when RALPH_SKIP_PERMISSIONS=true
  --append-system-prompt-file "$skills_file"  # when skills exist
```

The prompt is piped to stdin. Max turns is a system-level safety net from `RALPH_DEFAULT_MAX_TURNS` (default 200), not configured per-task.

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
  "duration_ms": 45000,
  "duration_api_ms": 40000,
  "is_error": false,
  "num_turns": 8,
  "result": "{\"summary\":\"...\",\"freeform\":\"...\",\"task_completed\":{...},...}"
}
```

Note: `.result` is a **string containing JSON**, not a JSON object. This is why `parse_handoff_output()` must do a double-parse: first extract the string from the envelope, then parse the string as JSON. Validates inner JSON with `jq .`.

### 7.4 Handoff Persistence

`save_handoff(handoff_json, iteration)` writes to `.ralph/handoffs/handoff-NNN.json` with zero-padded iteration numbers (e.g., `handoff-001.json`, `handoff-012.json`). Creates directory if absent. Returns the file path via stdout.

### 7.5 Response Metadata

`extract_response_metadata(response)` extracts `{cost_usd, duration_ms, num_turns, is_error}` from the envelope for telemetry.

### 7.6 MCP Configurations

Three MCP config files control which tools each agent type has access to:

| Config File | Used By | Tools Available |
|------------|---------|----------------|
| `mcp-coding.json` | Coding iterations | Empty `mcpServers: {}` — coding agent has NO MCP tools |
| `mcp-context.json` | Context agent (prep/post) | Context7 (`@upstash/context7-mcp`) for library docs |
| `mcp-memory.json` | Knowledge indexer | Context7 + Knowledge Graph Memory Server (cross-session entity/relation storage in `.ralph/memory.jsonl`) |

**Critical design choice**: The coding agent has NO MCP tools. Everything it needs must be in the prompt. The context agent fetches library docs via Context7 and includes them in the prepared prompt.

### 7.7 Dry-Run Behavior

Both `run_coding_iteration()` and `run_memory_iteration()` return synthetic valid response envelopes when `DRY_RUN=true`. This exercises the full pipeline without API calls.

---

## 8. Handoff Documents

### 8.1 Schema Structure

Every coding iteration produces a handoff JSON matching `handoff-schema.json`.

**Required fields**:

| Field | Type | Purpose |
|-------|------|---------|
| `summary` | string | One-line description of what was accomplished |
| `freeform` | string (min 50 chars) | **The most important field.** Narrative briefing for the next iteration |
| `task_completed` | `{task_id, summary, fully_complete}` | Task completion status |
| `deviations` | `[{planned, actual, reason}]` | Where implementation diverged from plan |
| `bugs_encountered` | `[{description, resolution, resolved}]` | Bugs found |
| `architectural_notes` | `[string]` | Design decisions made |
| `unfinished_business` | `[{item, reason, priority}]` | Incomplete work (priority: high/medium/low) |
| `recommendations` | `[string]` | Suggestions for next steps |
| `files_touched` | `[{path, action}]` | Files created/modified/deleted |
| `plan_amendments` | `[{action, task_id, task, changes, after, reason}]` | Proposed plan changes (action: add/modify/remove) |
| `tests_added` | `[{file, test_names}]` | Tests written |
| `constraints_discovered` | `[{constraint, impact, workaround?}]` | Discovered limitations |

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

In `handoff-plus-index` mode, `check_compaction_trigger(state_file, task_json)` evaluates whether to run the knowledge indexer. Triggers are checked in order; first match wins:

| Priority | Trigger | Condition | Rationale |
|----------|---------|-----------|-----------|
| 1 | Task metadata | `needs_docs == true` OR `libraries[]` non-empty | Task needs external docs; indexer uses MCP to fetch them |
| 2 | Semantic novelty | Term overlap between task and recent 3 handoffs < 0.25 | New topic area; past handoffs won't help |
| 3 | Byte threshold | Accumulated handoff bytes > 32000 (~8000 tokens) | Too much unindexed data |
| 4 | Periodic | Iterations since last compaction >= 5 | Regular indexing cadence |

**Novelty calculation**: `build_task_term_signature()` and `build_recent_handoff_term_signature()` tokenize text into sorted unique lowercase terms (length > 2, strip non-alphanumeric). `calculate_term_overlap()` computes `|intersection(task_terms, handoff_terms)| / |task_terms|`. Overlap < `RALPH_NOVELTY_OVERLAP_THRESHOLD` (default 0.25) means the task diverges significantly from recent work.

### 9.2 Knowledge Indexer Flow

`run_knowledge_indexer(task_json)`:
1. `build_compaction_input()` — Aggregate L2 data from all handoffs newer than `last_compaction_iteration`. Each formatted under `--- Iteration N ---` headers.
2. `build_indexer_prompt()` — Combine knowledge-index-prompt.md template + existing knowledge-index.md + new handoff data.
3. `snapshot_knowledge_indexes()` — Save current `.ralph/knowledge-index.{md,json}` to temp files for rollback. Backup format: first line "1" if file existed, "0" if not.
4. `run_memory_iteration(prompt)` — Claude writes knowledge-index.{md,json} directly via its built-in file tools.
5. `verify_knowledge_indexes()` — Run 4 invariant checks. On failure, `restore_knowledge_indexes()` reverts both files.
6. `update_compaction_state()` — Reset counters: `coding_iterations_since_compaction=0`, `total_handoff_bytes_since_compaction=0`, `last_compaction_iteration=current_iteration`.

### 9.3 L1/L2/L3 Extraction Levels

| Level | Function | Size | Content | Used By |
|-------|----------|------|---------|---------|
| L1 | `extract_l1()` | ~20-50 tokens | `[task-id] Summary. Complete/Partial. N files.` | Historical context lists |
| L2 | `extract_l2()` | ~200-500 tokens | JSON: `{task, decisions, deviations, constraints, failed, unfinished}` | Previous iteration context, `build_compaction_input()` |
| L3 | `extract_l3()` | 1 line | File path string | Deep-dive reference |

### 9.4 Post-Indexer Verification

All 4 checks must pass or the index files are rolled back to their pre-indexer snapshot:

**Check 1 — `verify_knowledge_index_header()`**:
- File must contain `^# Knowledge Index$` on a line
- File must contain `^Last updated: iteration [0-9]+ \(.+\)$` on a line

**Check 2 — `verify_hard_constraints_preserved()`**:
- Extract all lines under `## Constraints` in the PREVIOUS index containing `must`, `must not`, or `never` (case-insensitive)
- Each such line must either: (a) appear identically in the new index, OR (b) have its memory ID referenced in a `[supersedes: K-<type>-<slug>]` tag in the new index, OR (c) appear in a `Superseded: <original line>` legacy format
- Rationale: Hard constraints are safety-critical and must never be silently dropped

**Check 3 — `verify_json_append_only()`**:
- `knowledge-index.json` must be a JSON array
- Each entry must have: `iteration` (number), `task` (string), `summary` (string), `tags` (array)
- Array length must be >= previous length (no entries removed)
- All previous entries preserved exactly (deep equality per iteration key)
- No duplicate `iteration` values

**Check 4 — `verify_knowledge_index()`**:
- No two entries with `status: "active"` (or missing status, which defaults to active) may share the same `memory_id`
- Every ID referenced in a `supersedes` field must exist as a `memory_id` somewhere in the array

### 9.5 Knowledge Index Format

**Markdown** (`knowledge-index.md`):
```markdown
# Knowledge Index
Last updated: iteration 6 (2026-02-07T14:30:00Z)

## Constraints
- [K-constraint-no-force-push] Never force push to main [source: iter 2,5]

## Architectural Decisions
- [K-decision-bats-framework] Use bats-core for all shell testing [source: iter 1]

## Patterns
- [K-pattern-temp-rename] Use temp-file-then-rename for atomic writes [source: iter 3]

## Gotchas
- [K-gotcha-jq-string-result] Claude CLI .result is a JSON string, requires double-parse [source: iter 4]

## Unresolved
- [K-unresolved-mcp-timeout] Context7 MCP server occasionally times out [source: iter 6]
```

Memory ID format: `K-<type>-<slug>` where type is one of: `constraint`, `decision`, `pattern`, `gotcha`, `unresolved`.
Supersession: `[supersedes: K-<type>-<slug>]` inline on the replacement entry.
Provenance: `[source: iter N,M]` inline.

**JSON** (`knowledge-index.json`):
```json
[
  {
    "iteration": 6,
    "task": "TASK-003",
    "summary": "One-line summary of knowledge gained",
    "tags": ["testing", "git-ops"],
    "memory_ids": ["K-constraint-no-force-push", "K-decision-bats-framework"],
    "source_iterations": [6],
    "status": "active"
  }
]
```

---

## 10. Agent-Orchestrated Mode (agents.sh)

### 10.1 Architecture

Two-agent architecture: a **context agent** prepares pristine context for a **coding agent**, then organizes the coding agent's output into accumulated knowledge. Optional agent passes run afterward.

**Agent call sequence per iteration**:
1. **Context prep** (pre-coding): Reads all available artifacts, fetches library docs via Context7 MCP, assembles tailored prompt, detects stuck patterns. Returns directive (proceed/skip/review/research).
2. **Coding agent**: Receives the prepared prompt. Implements the task. Writes handoff with gained insights. Can signal back: `request_research`, `request_human_review`, `confidence_level`.
3. **Context post** (post-coding): Processes handoff into knowledge index. Detects failure patterns across iterations. Recommends next action.
4. **Optional passes**: Configurable agents (e.g., code review with cheaper model) run based on trigger conditions.

### 10.2 Generic Agent Invocation

`run_agent_iteration(prompt, schema_file, mcp_config, max_turns, model, system_prompt_file)` — unified entry point for all agent types. Constructs CLI args including `-p`, `--output-format json`, `--json-schema`, `--strict-mcp-config`, `--mcp-config`, `--max-turns`, and optionally `--model` and `--append-system-prompt-file`.

`parse_agent_output(response)` — same double-parse as `parse_handoff_output()` in cli-ops.sh.

### 10.3 Context Preparation

**Input building** (`build_context_prep_input(task_json, iteration, mode)`):

The context agent receives a lightweight manifest with:
- Current task details (inlined — always small)
- Task metadata: retry count, max retries, skills, libraries, needs_docs
- Available context file **paths** (NOT content): latest handoff, all handoffs count/range, knowledge index paths, failure context path, validation log path, skills directory, templates
- Research requests from previous coding agent's handoff (`request_research` field)
- Human review signals and confidence level from previous coding agent (if not "high")
- State: current iteration, mode, plan file
- Output file path: `.ralph/context/prepared-prompt.md`

**Critical design**: The manifest contains file pointers, not file contents. The context agent uses its Read tool and MCP tools to access what it needs. This keeps the input small and lets the agent exercise judgment about what to read.

**Execution** (`run_context_prep(task_json, iteration, mode)`):
1. Build manifest
2. Load system prompt from `context-prep-prompt.md`
3. Delete stale `prepared-prompt.md` so we can detect if agent wrote a new one
4. Invoke context agent with `context-prep-schema.json` + `mcp-context.json`
5. In dry-run: create stub prepared prompt
6. Verify `prepared-prompt.md` exists and is >= 50 bytes
7. Return directive JSON

**Context Prep Directives**:

| Action | Meaning | Orchestrator Response |
|--------|---------|----------------------|
| `proceed` | Coding prompt is ready | Continue to coding phase |
| `skip` | Task should be skipped | Set task status to "skipped", continue loop |
| `request_human_review` | Human judgment needed | Set task to "pending", set status to "paused", break loop |
| `research` | More research needed | Set task to "pending", continue loop (context agent gets another chance) |

**Stuck Detection**: The context prep agent must populate `stuck_detection.is_stuck` (boolean). When true, the orchestrator emits a `stuck_detected` telemetry event with evidence and suggested action. The agent analyzes retry counts, failure patterns, and consecutive handoff narratives.

### 10.4 Context Post-Processing

**Purpose**: Organize the coding agent's output into accumulated knowledge. Runs after EVERY iteration (including failed validations) because the context agent needs to see failure patterns.

**Input** (`build_context_post_input(handoff_file, iteration, task_id, validation_result)`):
- Completed iteration details (iteration number, task ID, validation result, handoff path)
- Validation log path (if exists)
- Knowledge index file paths (or "does not exist yet")
- Recent handoff paths (last 5, for pattern detection)
- Verification rules reminder

**Execution** (`run_context_post`):
1. Build manifest
2. Snapshot existing knowledge indexes (reuses compaction.sh machinery)
3. Invoke context agent with `context-post-schema.json` + `mcp-context.json`
4. Verify knowledge index integrity via `verify_knowledge_indexes()`. On failure, restore snapshots (non-fatal — directive is still returned)
5. Reset compaction counters
6. Return directive JSON (or sensible defaults if parse fails)

**Post-processing directives** (advisory — logged and visible to next context prep pass, but do NOT break the main loop):
- `proceed` — Continue normally
- `skip_task` — Task should be skipped
- `modify_plan` — Plan needs adjustment (with `plan_suggestions`)
- `request_human_review` — Situation needs human judgment
- `increase_retries` — Task needs more attempts

### 10.5 Agent Pass Framework

Configurable optional agents that run after each iteration. Configured in `.ralph/config/agents.json` under `passes[]`.

**Pass configuration**:
```json
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
```

**Trigger types**:
| Trigger | Fires When |
|---------|-----------|
| `always` | Every iteration |
| `on_success` | Validation passed |
| `on_failure` | Validation failed |
| `periodic:N` | Every N iterations (`iteration % N == 0`) |

**Critical invariant**: Agent passes are NON-FATAL. Failures are logged but never block the main loop. `run_agent_passes()` always returns 0.

**The code review pass** (included as skeleton, disabled by default): Reads the handoff to understand changes, reads `files_touched`, checks for security vulnerabilities, logic errors, convention violations, test coverage gaps. Returns `{review_passed, issues[], summary}`.

---

## 11. Git Operations (git-ops.sh)

### 11.1 Transactional Semantics

Every iteration is bracketed by checkpoint/commit-or-rollback:

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

| Function | Purpose |
|----------|---------|
| `create_checkpoint()` | Captures `git rev-parse HEAD` as rollback target. Outputs 40-char SHA to stdout |
| `rollback_to_checkpoint(sha)` | `git reset --hard $sha && git clean -fd --exclude=.ralph/` |
| `commit_iteration(iteration, task_id, message)` | `git add -A && git commit -m "${RALPH_COMMIT_PREFIX:-ralph}[${iteration}]: ${task_id} — ${message}"` |
| `ensure_clean_state()` | Auto-commits dirty working tree at startup with `"ralph: auto-commit before orchestration start"` |

### 11.3 Invariants

- After every iteration, the repo is either committed (success) or rolled back to checkpoint (failure). No partial states persist.
- `.ralph/` directory is NEVER cleaned by rollback (`--exclude=.ralph/`). This preserves handoffs, logs, state, and control files across rollbacks.
- Iteration commits are local, linear commits. No rebase, merge, or conflict resolution — delegated to higher-level orchestration/user workflow.

---

## 12. Plan Operations (plan-ops.sh)

### 12.1 Task Selection

`get_next_task(plan_file)` — dependency-aware selection:
1. Filter to tasks with `status == "pending"`
2. A candidate is runnable only when ALL IDs in `depends_on` resolve to tasks with `status == "done"`
3. Return the first runnable task in `.tasks` array order
4. Return empty if nothing is runnable

Selection is deterministic: repeated calls without plan mutation return the same task.

### 12.2 Status Transitions

`set_task_status(plan_file, task_id, new_status)` — atomic update via temp-file-then-rename.

Task status lifecycle: `pending` → `in_progress` → `done` | `failed` | `skipped`

### 12.3 Plan Amendments

`apply_amendments(plan_file, handoff_file, current_task_id)` processes `plan_amendments[]` from handoff:

**Safety guardrails**:
- **Max 3 amendments per iteration** — entire batch rejected if exceeded
- **Cannot modify current task's status** — prevents self-modification
- **Cannot remove tasks with status "done"** — preserves completed work
- Creates `plan.json.bak` before first mutation
- All mutations logged to `.ralph/logs/amendments.log` with timestamps and ACCEPTED/REJECTED status

**Operations**:
- `add`: Requires id, title, description. Defaults for optional fields (status: pending, order: 999). Can insert `after` a specific task ID, otherwise appends.
- `modify`: Merges `changes` object into task by ID. Status changes to the current task are rejected.
- `remove`: Drops task by ID. Tasks with `status: "done"` cannot be removed.

Individual invalid amendments are skipped; processing continues for remaining items.

### 12.4 Completion Checks

- `is_plan_complete()` — Returns 0 if ALL tasks have `status == "done"` or `status == "skipped"`. Note: `failed` tasks do NOT count as complete.
- `count_remaining_tasks()` — Returns count of `pending` + `failed` tasks (does not include `skipped`).

---

## 13. Validation (validation.sh)

### 13.1 Command Classification

`classify_command(cmd)` tags each command:
- **"lint"**: Commands matching `shellcheck|lint|eslint|flake8|pylint|stylelint`
- **"test"**: Commands matching `bats|test|pytest|jest|cargo test|mocha|rspec`
- **"test" (default)**: Unknown commands default to "test" (fail-safe — they block progress)

### 13.2 Execution

`run_validation(iteration)`:
1. Iterate through `RALPH_VALIDATION_COMMANDS` array
2. For each: `classify_command()`, execute via `eval`, capture stdout+stderr and exit code
3. `evaluate_results()` applies strategy
4. Write results to `.ralph/logs/validation/iter-N.json`
5. Return 0 (pass) or 1 (fail)

**Empty validation commands**: If `RALPH_VALIDATION_COMMANDS` is empty, validation auto-passes with a warning log. This can silently mask real failures.

### 13.3 Strategies

| Strategy | Tests must pass? | Lint must pass? |
|----------|------------------|-----------------|
| `strict` (default) | Yes | Yes |
| `lenient` | Yes | No |
| `tests_only` | Yes | No (ignored entirely) |

### 13.4 Failure Context Generation

`generate_failure_context(result_file)`:
- Reads validation result JSON, filters to failed checks
- Formats as markdown with `### Validation Failures` header
- Truncates each check's output to 500 chars to conserve prompt budget
- Saved to `.ralph/context/failure-context.md` by the caller
- **Consumed once**: deleted after successful handoff parse in the next iteration (deferred deletion prevents loss if the retry cycle fails mid-flight)

---

## 14. Telemetry and Control (telemetry.sh)

### 14.1 Event Stream

`emit_event(type, message, metadata)` appends one JSONL line to `.ralph/logs/events.jsonl`:
```json
{"timestamp":"2026-02-07T14:30:00Z","event":"iteration_start","message":"Starting iteration 5","metadata":{"iteration":5,"task_id":"TASK-003"}}
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

No fsync forced — durability is OS-buffered best effort.

### 14.2 Operator Control Plane

**Command Queue** (`.ralph/control/commands.json`):
```json
{"pending": [{"command": "pause"}, {"command": "inject-note", "note": "Check the API rate limits"}]}
```

Dashboard POSTs commands → `serve.py` enqueues → `check_and_handle_commands()` at loop top:

| Command | Effect |
|---------|--------|
| `pause` | Sets `RALPH_PAUSED=true`. Loop blocks in `wait_while_paused()` polling every `RALPH_PAUSE_POLL_SECONDS` (default 5s) |
| `resume` | Sets `RALPH_PAUSED=false`. Loop unblocks |
| `inject-note` | Emits a `note` event with the provided text. No loop effect |
| `skip-task` | Calls `set_task_status(task_id, "skipped")`. Emits telemetry event |

**Delivery semantics**: At-least-once best effort. Commands may be replayed if a crash happens after execution but before `clear_pending_commands()`. Unknown commands are logged and skipped (non-fatal). Stale commands treated as idempotent state-set operations.

---

## 15. Progress Logging (progress-log.sh)

### 15.1 Dual-Format Output

After each successful iteration, `append_progress_entry(handoff_file, iteration, task_id)` produces:

**`.ralph/progress-log.md`** — Human/LLM-readable:
- Header with plan name
- Summary table (Task | Status | Summary) rebuilt from plan.json each time
- Per-iteration `### TASK-ID: Title (Iteration N)` blocks with: summary, files changed table, tests added, design decisions, constraints, deviations, bugs

**`.ralph/progress-log.json`** — Machine-readable:
```json
{
  "generated_at": "2026-02-07T14:30:00Z",
  "plan_summary": {"total_tasks": 12, "completed": 3, "pending": 8, "failed": 1, "skipped": 0},
  "entries": [{"task_id": "TASK-002", "iteration": 3, "summary": "...", "files_changed": [...], ...}]
}
```

### 15.2 Update Semantics

- JSON: Deduplicates by `(task_id, iteration)`, refreshes `generated_at`, recomputes `plan_summary` from current plan.json
- Markdown: Fully regenerated — summary table always reflects latest task statuses
- Conditional section emission — omits empty arrays (no "Deviations:" section if deviations is empty)

**Task title resolution**: Uses `get_task_by_id()` from plan-ops.sh (guarded with `declare -f`). Falls back to using task_id as the title if plan-ops.sh isn't available.

---

## 16. Dashboard and HTTP Server

### 16.1 `serve.py` (233 lines)

A Python HTTP server that bridges the dashboard UI and Ralph's file-based control plane.

**Endpoints**:

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/*` | Serve static files from project root (dashboard, state.json, plan.json, handoffs/, events.jsonl, progress-log.json) |
| POST | `/api/command` | Accept command object, append to `commands.json` `pending[]` |
| POST | `/api/settings` | Accept settings update, apply whitelisted keys to `ralph.conf` |
| OPTIONS | `*` | CORS preflight |

**Settings whitelist** (only these can be changed from the dashboard):
`RALPH_VALIDATION_STRATEGY`, `RALPH_COMPACTION_INTERVAL`, `RALPH_COMPACTION_THRESHOLD_BYTES`, `RALPH_DEFAULT_MAX_TURNS`, `RALPH_MIN_DELAY_SECONDS`, `RALPH_MODE`

**Security**: Values sanitized to match `^[a-zA-Z0-9_-]+$` — rejects anything that could inject shell syntax. All writes use `atomic_write()` (temp-file-then-`os.replace()`).

**Startup**: `python3 .ralph/serve.py --port 8080 --bind 127.0.0.1`

### 16.2 `dashboard.html`

Single-file vanilla JavaScript + Tailwind CSS dashboard. Polls server every 3 seconds for state updates.

**Views** (6 screenshot captures exist):
1. Main dashboard — iteration status, task progress, cost tracking
2. Handoff detail — expanded view of individual handoff content
3. Handoff-only mode view
4. Architecture tab — system overview
5. Progress log detail — per-task execution history
6. Settings panel — runtime configuration controls

---

## 17. State Files

### 17.1 `state.json`

Runtime state persisted across iterations:
```json
{
  "current_iteration": 0,
  "last_compaction_iteration": 0,
  "coding_iterations_since_compaction": 0,
  "total_handoff_bytes_since_compaction": 0,
  "last_task_id": null,
  "started_at": null,
  "status": "idle",
  "mode": "handoff-only"
}
```

Status values: `idle`, `running`, `complete`, `blocked`, `interrupted`, `paused`, `max_iterations_reached`.

Read/written via `read_state(key)` / `write_state(key, value)`. Writes use temp-file-then-rename. The `write_state` jq expression auto-coerces value types (number, bool, null, string).

### 17.2 `plan.json`

Task plan at project root:
```json
{
  "project": "ralph-deluxe",
  "branch": "main",
  "max_iterations": 50,
  "validation_strategy": "strict",
  "tasks": [
    {
      "id": "TASK-001",
      "title": "Create directory structure and config files",
      "description": "Set up the project scaffold...",
      "status": "done",
      "order": 1,
      "skills": ["bash-conventions", "jq-patterns"],
      "needs_docs": false,
      "libraries": [],
      "acceptance_criteria": ["All directories from the spec exist"],
      "depends_on": [],
      "retry_count": 0,
      "max_retries": 2
    }
  ]
}
```

**Task status lifecycle**: `pending` → `in_progress` → `done` | `failed` | `skipped`

**Retry mechanics**: `retry_count` is incremented on each failure. When `retry_count >= max_retries` (default 2), the task is marked `failed`. Retries are tracked per-task in plan.json (not in state.json) because retries are task-specific.

### 17.3 `commands.json`

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
| `RALPH_MIN_DELAY_SECONDS` | 30 | ralph.sh | Rate limit delay between iterations |
| `RALPH_MODEL` | `""` (default) | cli-ops.sh | Model override (empty = default) |
| `RALPH_FALLBACK_MODEL` | `sonnet` | cli-ops.sh | Fallback model |
| `RALPH_SKIP_PERMISSIONS` | `true` | cli-ops.sh, agents.sh | Pass `--dangerously-skip-permissions` to claude CLI |
| `RALPH_AUTO_COMMIT` | `true` | git-ops.sh | Auto-commit on successful validation |
| `RALPH_COMMIT_PREFIX` | `ralph` | git-ops.sh | Prefix for commit messages |
| `RALPH_LOG_LEVEL` | `info` | ralph.sh | `debug` / `info` / `warn` / `error` |
| `RALPH_LOG_FILE` | `.ralph/logs/ralph.log` | ralph.sh | Log file path |
| `RALPH_VALIDATION_STRATEGY` | `strict` | validation.sh | `strict` / `lenient` / `tests_only` |
| `RALPH_VALIDATION_COMMANDS` | (array) | validation.sh | Shell commands to run for validation |
| `RALPH_CONTEXT_BUDGET_TOKENS` | 8000 | context.sh | Token budget (handoff-only mode) |
| `RALPH_CONTEXT_BUDGET_TOKENS_HPI` | 16000 | context.sh | Token budget (handoff-plus-index mode) |
| `RALPH_COMPACTION_INTERVAL` | 5 | compaction.sh | Iterations between periodic indexer runs |
| `RALPH_COMPACTION_THRESHOLD_BYTES` | 32000 | compaction.sh | Byte threshold for indexer trigger |
| `RALPH_COMPACTION_MAX_TURNS` | 10 | cli-ops.sh | Max turns for memory/indexer CLI calls |
| `RALPH_DEFAULT_MAX_TURNS` | 200 | cli-ops.sh | Safety-net max tool-use rounds per coding iteration |
| `RALPH_NOVELTY_OVERLAP_THRESHOLD` | 0.25 | compaction.sh | Novelty trigger threshold |
| `RALPH_NOVELTY_RECENT_HANDOFFS` | 3 | compaction.sh | Handoffs for novelty calculation |
| `RALPH_CONTEXT_AGENT_MODEL` | `""` | agents.sh | Model override for context agent |
| `RALPH_AGENT_PASSES_ENABLED` | `true` | ralph.sh | Enable/disable optional agent passes |
| `RALPH_PAUSE_POLL_SECONDS` | 5 | telemetry.sh | Pause polling interval |

### 18.1 `agents.json` — Agent Pass Configuration

```json
{
  "context_agent": {
    "model": null,
    "prep": { "max_turns": 25, "prompt_template": "context-prep-prompt.md", "schema": "context-prep-schema.json", "mcp_config": "mcp-context.json", "output_file": ".ralph/context/prepared-prompt.md" },
    "post": { "max_turns": 10, "prompt_template": "context-post-prompt.md", "schema": "context-post-schema.json", "mcp_config": "mcp-context.json" }
  },
  "passes": [
    { "name": "review", "enabled": false, "model": "haiku", "trigger": "on_success", "max_turns": 5, "prompt_template": "review-agent-prompt.md", "schema": "review-agent-schema.json", "mcp_config": "mcp-coding.json", "read_only": true }
  ]
}
```

---

## 19. JSON Schemas

### 19.1 Handoff Schema (`handoff-schema.json`)

Required output from every coding iteration. Fields documented in Section 8.

### 19.2 Context Prep Schema (`context-prep-schema.json`)

Output from context preparation agent:
- `action` (required): enum `proceed` / `skip` / `request_human_review` / `research`
- `reason` (required): string explaining the action
- `stuck_detection` (required): `{is_stuck: bool, evidence?: string, suggested_action?: string}`
- `prompt_token_estimate`: approximate token count of prepared prompt
- `sections_included`: which prompt sections were included
- `context_notes`: internal reasoning (logged but not acted upon)

### 19.3 Context Post Schema (`context-post-schema.json`)

Output from knowledge organization agent:
- `knowledge_updated` (required): boolean
- `recommended_action` (required): enum `proceed` / `skip_task` / `modify_plan` / `request_human_review` / `increase_retries`
- `summary` (required): one-line summary
- `failure_pattern_detected`: boolean
- `failure_pattern`: description of detected pattern
- `plan_suggestions`: array of `{action, task_id, reason}`
- `coding_agent_signals`: `{research_requests: string[], human_review_requested: bool, confidence_assessment: enum}`

### 19.4 Review Agent Schema (`review-agent-schema.json`)

Output from code review agent pass:
- `review_passed` (required): boolean
- `issues` (required): array of `{severity: critical/warning/suggestion, file?: string, description, suggested_fix?: string}`
- `summary` (required): string

### 19.5 Memory Output Schema (`memory-output-schema.json`)

Legacy compaction output:
- `project_summary` (required): string
- `completed_work` (required): string[]
- `active_constraints` (required): array of `{constraint, source_iteration?}`
- `architectural_decisions` (required): string[]
- `file_knowledge` (required): array of `{path, purpose}`
- `unresolved_issues`: string[]
- `library_docs`: array of `{library, key_apis, usage_notes?}`

---

## 20. Skills System

Skills are markdown files in `.ralph/skills/` that provide coding conventions and tool usage reference. They are injected into the prompt's `## Skills` section when a task's `skills[]` array references them.

| Skill File | Content |
|-----------|---------|
| `bash-conventions.md` | Script headers, variable naming, conditionals, error handling, logging, function style |
| `git-workflow.md` | Checkpoint/rollback/commit patterns, commit message format, rules (never force push, etc.) |
| `jq-patterns.md` | Reusable jq recipes for plan/handoff/state JSON operations, safe in-place update pattern |
| `testing-bats.md` | bats-core test syntax, `run` command, setup/teardown, assertions without bats-assert |
| `mcp-config.md` | MCP strict mode, config file selection, Context7 two-step usage, Knowledge Graph Memory Server tools |

Skills are loaded by `load_skills()` in context.sh. Missing skill files log a warning but don't fail prompt assembly.

In agent-orchestrated mode: the context agent reads skill files directly and incorporates them into the prepared prompt.

---

## 21. Templates

### 21.1 Coding Agent Templates

**`coding-prompt-footer.md`**: Output instructions for the coding agent. Tells it to produce valid JSON matching the handoff schema, with emphasis on `freeform` as the most important field — write as if briefing a colleague.

**`coding-prompt.md`**: Reference blueprint (fallback if footer template missing).

**`first-iteration.md`**: Bootstrap context for iteration 1. Signals clean slate, emphasizes importance of thorough handoff documentation since it seeds all future context.

### 21.2 Context Agent Templates

**`context-prep-prompt.md`**: System prompt for the context preparation agent. Core principle: **the coding agent should never have to research anything**. Responsibilities: research library docs via Context7 MCP, analyze handoffs/knowledge/failures, detect stuck patterns, write self-contained prompt with exact 7-section headers, return directive. Guidelines: clarity over brevity, pre-digest everything (don't link — inline), synthesize don't dump, highlight risks, preserve hard constraints.

**`context-post-prompt.md`**: System prompt for the knowledge organization agent. Responsibilities: update knowledge-index.{md,json} following memory ID format, detect failure patterns, process coding agent signals, return recommendations. Verification rules embedded.

### 21.3 Other Templates

**`knowledge-index-prompt.md`**: Instructions for the periodic knowledge indexer (h+i mode). Covers dual-file format, entry format with stable memory IDs, and all 4 verification rules.

**`memory-prompt.md`**: Legacy template for v1 compaction system.

**`review-agent-prompt.md`**: System prompt for READ-ONLY code review agent. Checks for: security vulnerabilities, logic errors, missing error handling, convention violations, test coverage gaps. Does NOT flag: style preferences, minor formatting, theoretical edge cases.

---

## 22. Error Handling, Retry, and Rollback

### 22.1 Coding Cycle Failure

When `run_coding_cycle()` or `run_agent_coding_cycle()` returns non-zero:

1. **Agent directive check** (agent-orchestrated only): stderr checked for `DIRECTIVE:skip`, `DIRECTIVE:request_human_review`, `DIRECTIVE:research`. These are NOT coding failures — they're context agent recommendations.
2. `rollback_to_checkpoint()` — hard reset to pre-iteration SHA + clean untracked files (excluding `.ralph/`)
3. `increment_retry_count()` — increment task's retry count in plan.json
4. If `retry_count >= max_retries` → `set_task_status("failed")`
5. Task stays/returns to `pending` (or `failed`) and the loop continues

### 22.2 Validation Failure

When `run_validation()` returns 1:

1. `rollback_to_checkpoint()` — same as above
2. `increment_retry_count()` — same as above
3. `generate_failure_context()` → saves to `.ralph/context/failure-context.md`
4. On next iteration of the same task, failure context is injected into `## Failure Context` section
5. **Failure context lifecycle**: Created on validation failure → read on next attempt → deleted after successful handoff parse (deferred deletion prevents loss if the retry cycle fails mid-flight)

### 22.3 Knowledge Index Verification Failure

When `verify_knowledge_indexes()` returns 1:

1. `restore_knowledge_indexes()` reverts both `.ralph/knowledge-index.{md,json}` from snapshots
2. Compaction counters are NOT reset (so the trigger will fire again)
3. The main loop continues — knowledge index verification failure is non-fatal

### 22.4 Non-Fatal Operations

Several operations are explicitly non-fatal:
- Progress log updates: failure logged, iteration continues
- Amendment application: individual amendments rejected, batch continues
- Agent passes: failures logged, main loop continues
- Context post-processing: failure logged, main loop continues
- Knowledge index verification failure: changes rolled back, orchestrator proceeds

### 22.5 Graceful Shutdown

`SIGINT`/`SIGTERM` → `shutdown_handler()`:
1. Reentrant guard: if `SHUTTING_DOWN=true`, return immediately
2. Set `SHUTTING_DOWN=true`
3. Emit `orchestrator_end` event (if telemetry is available)
4. Write `status: "interrupted"` to state.json
5. Exit 130

### 22.6 Resume

`--resume` flag: reads `current_iteration` from state.json and continues from there. Without `--resume`, iteration resets to 0 and status is set to "running".

### 22.7 Graceful Degradation

All cross-module function calls are guarded with `declare -f` checks:
```bash
if declare -f emit_event >/dev/null 2>&1; then
    emit_event "iteration_start" "..."
fi
```

This means:
- Missing modules don't crash the orchestrator
- Individual subsystems degrade independently
- Tests can source individual modules without loading the full system

---

## 23. Cross-Module Function Dependencies

### 23.1 Complete Call Graph

```
ralph.sh
  ├── parse_args(), load_config(), source_libs(), read_state(), write_state()
  ├── prepare_skills_file()
  │     └── load_skills() [context.sh]
  ├── run_coding_cycle()
  │     ├── prepare_skills_file() [self]
  │     ├── build_coding_prompt_v2() [context.sh]
  │     │     ├── get_prev_handoff_for_mode() [context.sh]
  │     │     └── _latest_handoff_file(), _safe_jq_file() [context.sh]
  │     ├── get_budget_for_mode() [context.sh]
  │     ├── truncate_to_budget() [context.sh]
  │     ├── estimate_tokens() [context.sh]
  │     ├── run_coding_iteration() [cli-ops.sh]
  │     ├── parse_handoff_output() [cli-ops.sh]
  │     ├── save_handoff() [cli-ops.sh]
  │     └── extract_response_metadata() [cli-ops.sh]
  ├── run_agent_coding_cycle()
  │     ├── run_context_prep() [agents.sh]
  │     │     ├── build_context_prep_input() [agents.sh]
  │     │     └── run_agent_iteration() [agents.sh]
  │     ├── handle_prep_directives() [agents.sh]
  │     ├── read_prepared_prompt() [agents.sh]
  │     ├── prepare_skills_file() [self]
  │     ├── run_coding_iteration() [cli-ops.sh]
  │     ├── parse_handoff_output() [cli-ops.sh]
  │     └── save_handoff() [cli-ops.sh]
  ├── Main loop calls:
  │     ├── check_and_handle_commands() [telemetry.sh]
  │     ├── is_plan_complete() [plan-ops.sh]
  │     ├── get_next_task() [plan-ops.sh]
  │     ├── set_task_status() [plan-ops.sh]
  │     ├── check_compaction_trigger() [compaction.sh]
  │     ├── run_knowledge_indexer() [compaction.sh]
  │     ├── create_checkpoint() [git-ops.sh]
  │     ├── rollback_to_checkpoint() [git-ops.sh]
  │     ├── commit_iteration() [git-ops.sh]
  │     ├── run_validation() [validation.sh]
  │     ├── generate_failure_context() [validation.sh]
  │     ├── apply_amendments() [plan-ops.sh]
  │     ├── append_progress_entry() [progress-log.sh]
  │     ├── emit_event() [telemetry.sh]
  │     ├── run_context_post() [agents.sh]
  │     ├── handle_post_directives() [agents.sh]
  │     └── run_agent_passes() [agents.sh]
  └── increment_retry_count() [self]

agents.sh
  ├── run_agent_iteration() — generic CLI invocation
  ├── parse_agent_output() — double-parse (same as parse_handoff_output)
  ├── run_context_prep() → build_context_prep_input()
  ├── run_context_post() → build_context_post_input()
  │     ├── snapshot_knowledge_indexes() [compaction.sh]
  │     ├── verify_knowledge_indexes() [compaction.sh]
  │     ├── restore_knowledge_indexes() [compaction.sh]
  │     └── update_compaction_state() [compaction.sh]
  ├── handle_prep_directives(), handle_post_directives()
  │     └── emit_event() [telemetry.sh]
  └── run_agent_passes() → load_agent_passes_config(), build_pass_input(), check_pass_trigger()

compaction.sh
  ├── check_compaction_trigger() → tokenize_terms(), build_task_term_signature(),
  │     build_recent_handoff_term_signature(), calculate_term_overlap()
  ├── run_knowledge_indexer() → build_compaction_input(), build_indexer_prompt(),
  │     snapshot_knowledge_indexes(), run_memory_iteration() [cli-ops.sh],
  │     verify_knowledge_indexes(), restore_knowledge_indexes(), update_compaction_state()
  ├── extract_l1(), extract_l2(), extract_l3()
  └── verify_knowledge_index_header(), verify_hard_constraints_preserved(),
      verify_json_append_only(), verify_knowledge_index()

context.sh
  ├── build_coding_prompt_v2() → get_prev_handoff_for_mode(), _latest_handoff_file(), _safe_jq_file()
  ├── truncate_to_budget() — section-aware awk parser
  ├── load_skills(), estimate_tokens(), get_budget_for_mode()
  ├── retrieve_relevant_knowledge() — keyword matching (retained, not actively used)
  └── Legacy: build_coding_prompt(), get_prev_handoff_summary(), get_earlier_l1_summaries(),
      format_compacted_context()

progress-log.sh
  ├── append_progress_entry() → format_progress_entry_md(), format_progress_entry_json(),
  │     _generate_plan_summary_json(), _regenerate_progress_md()
  ├── _resolve_task_title() → get_task_by_id() [plan-ops.sh]
  └── init_progress_log()

telemetry.sh
  ├── emit_event(), init_control_file()
  ├── check_and_handle_commands() → process_control_commands() → read_pending_commands(),
  │     clear_pending_commands(), wait_while_paused()
  └── process_control_commands() → set_task_status() [plan-ops.sh] (for skip-task)
```

### 23.2 Function Index

#### ralph.sh
| Function | Signature | Purpose |
|----------|-----------|---------|
| `main` | `("$@")` | Orchestrator entry point |
| `parse_args` | `("$@")` | CLI argument parsing |
| `load_config` | `()` | Source ralph.conf |
| `read_state` | `(key)` | Read from state.json |
| `write_state` | `(key, value)` | Write to state.json atomically |
| `source_libs` | `()` | Source all .ralph/lib/*.sh |
| `prepare_skills_file` | `(task_json)` | Create temp file with skills content |
| `build_memory_prompt` | `(compaction_input, task_json?)` | Legacy memory agent prompt |
| `run_compaction_cycle` | `(task_json?)` | Legacy compaction (backward compat) |
| `run_agent_coding_cycle` | `(task_json, iteration)` | Agent-orchestrated coding cycle |
| `run_coding_cycle` | `(task_json, iteration)` | Standard coding cycle |
| `increment_retry_count` | `(plan_file, task_id)` | Bump retry_count in plan |
| `shutdown_handler` | `()` | SIGINT/SIGTERM handler (exit 130) |
| `log` | `(level, message)` | Central logging to file + stderr |

**Testability guard**: The `main()` call at EOF is wrapped in `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then` so tests can source the file without triggering the loop.

#### agents.sh
| Function | Signature | Purpose |
|----------|-----------|---------|
| `run_agent_iteration` | `(prompt, schema, mcp, turns, model?, sysprompt?)` | Generic agent invocation |
| `parse_agent_output` | `(response)` | Double-parse agent response |
| `build_context_prep_input` | `(task_json, iteration, mode)` | Prep agent manifest |
| `run_context_prep` | `(task_json, iteration, mode)` | Run context preparation |
| `read_prepared_prompt` | `()` | Read prepared-prompt.md |
| `build_context_post_input` | `(handoff, iteration, task_id, result)` | Post agent manifest |
| `run_context_post` | `(handoff, iteration, task_id, result)` | Run knowledge organization |
| `handle_prep_directives` | `(directive_json)` | Process prep directives |
| `handle_post_directives` | `(directive_json)` | Process post directives |
| `load_agent_passes_config` | `()` | Load enabled passes from agents.json |
| `build_pass_input` | `(name, handoff, iteration, task_id)` | Build pass manifest |
| `check_pass_trigger` | `(trigger, result, iteration)` | Check trigger condition |
| `run_agent_passes` | `(handoff, iteration, task_id, result)` | Run all matching passes |

#### cli-ops.sh
| Function | Signature | Purpose |
|----------|-----------|---------|
| `run_coding_iteration` | `(prompt, task_json, skills_file?)` | Invoke Claude for coding |
| `run_memory_iteration` | `(prompt)` | Invoke Claude for memory/indexer |
| `parse_handoff_output` | `(response)` | Double-parse response envelope |
| `save_handoff` | `(json, iteration)` | Persist handoff to disk |
| `extract_response_metadata` | `(response)` | Extract cost/duration/turns |

#### compaction.sh
| Function | Signature | Purpose |
|----------|-----------|---------|
| `check_compaction_trigger` | `(state_file, task_json?)` | Should indexer run? |
| `tokenize_terms` | `(text)` | Tokenize for novelty calc |
| `build_task_term_signature` | `(task_json)` | Task term signature |
| `build_recent_handoff_term_signature` | `(dir, limit)` | Handoff term signature |
| `calculate_term_overlap` | `(task_terms, handoff_terms)` | Overlap ratio |
| `extract_l1` / `extract_l2` / `extract_l3` | `(handoff_file)` | Context extraction |
| `build_compaction_input` | `(handoffs_dir?, state_file?)` | L2 data since compaction |
| `build_indexer_prompt` | `(compaction_input)` | Indexer prompt |
| `run_knowledge_indexer` | `(task_json?)` | Full indexer cycle |
| `snapshot_knowledge_indexes` | `(md, json, bak_md, bak_json)` | Save for rollback |
| `restore_knowledge_indexes` | `(md, json, bak_md, bak_json)` | Restore from backup |
| `verify_knowledge_indexes` | `(md, json, bak_md, bak_json)` | Run all 4 checks |
| `update_compaction_state` | `(state_file?)` | Reset counters |

#### plan-ops.sh
| Function | Signature | Purpose |
|----------|-----------|---------|
| `get_next_task` | `(plan_file?)` | Dependency-aware selection |
| `set_task_status` | `(plan_file, task_id, status)` | Update task status |
| `get_task_by_id` | `(plan_file, task_id)` | Lookup task by ID |
| `apply_amendments` | `(plan_file, handoff, current_task?)` | Apply plan mutations |
| `is_plan_complete` | `(plan_file?)` | All tasks done/skipped? |
| `count_remaining_tasks` | `(plan_file?)` | Pending + failed count |

#### validation.sh
| Function | Signature | Purpose |
|----------|-----------|---------|
| `classify_command` | `(cmd)` | Tag as "test" or "lint" |
| `run_validation` | `(iteration)` | Execute and evaluate |
| `evaluate_results` | `(checks_json, strategy)` | Apply strategy |
| `generate_failure_context` | `(result_file)` | Failure context markdown |

#### telemetry.sh
| Function | Signature | Purpose |
|----------|-----------|---------|
| `emit_event` | `(type, message, metadata?)` | Append JSONL event |
| `init_control_file` | `()` | Create commands.json |
| `check_and_handle_commands` | `()` | Process + maybe pause |
| `process_control_commands` | `()` | Execute all pending |
| `read_pending_commands` | `()` | Read command queue |
| `clear_pending_commands` | `()` | Reset pending array |
| `wait_while_paused` | `()` | Block until resume |

#### progress-log.sh
| Function | Signature | Purpose |
|----------|-----------|---------|
| `init_progress_log` | `()` | Create log files |
| `format_progress_entry_md` | `(handoff, iteration, task_id)` | Markdown entry |
| `format_progress_entry_json` | `(handoff, iteration, task_id)` | JSON entry |
| `append_progress_entry` | `(handoff, iteration, task_id)` | Append to both logs |

#### git-ops.sh
| Function | Signature | Purpose |
|----------|-----------|---------|
| `create_checkpoint` | `()` | Capture HEAD for rollback |
| `rollback_to_checkpoint` | `(sha)` | Hard reset + clean |
| `commit_iteration` | `(iteration, task_id, message)` | Stage and commit |
| `ensure_clean_state` | `()` | Auto-commit dirty tree |

---

## 24. Testing Infrastructure

### 24.1 Framework

**Framework**: bats-core. Test files in `tests/*.bats`. Each module has its own test file.

### 24.2 Test Helper (`tests/test_helper/common.sh`)

| Function | Purpose |
|----------|---------|
| `common_setup()` | Creates temp dir, exports `TEST_DIR` and `PROJ_ROOT`, sets default config env vars |
| `common_teardown()` | Removes temp dir |
| `create_test_git_repo()` | Initializes a git repo in `$TEST_DIR` with initial commit |
| `create_sample_plan()` | Writes a plan with 3 tasks: one done, one pending with a satisfied dependency, one pending with no deps |
| `create_sample_handoff()` | Writes sample handoff JSON with configurable task ID and completion status |
| `create_ralph_dirs()` | Creates full `.ralph` directory tree in `$TEST_DIR` |
| `create_test_state()` | Writes initial `state.json` with iteration 0, status idle |

**`log()` stub**: Exported as a no-op so library modules that call `log()` don't fail during tests.

### 24.3 Test Files and Coverage

| Test File | Module | Key Coverage |
|-----------|--------|-------------|
| `agents.bats` | agents.sh | Context prep/post input building, directive handling, pass triggers, agent config loading, dry-run flows, handoff signal fields |
| `cli-ops.bats` | cli-ops.sh | Response parsing, double-parse validation, dry-run responses, handoff saving |
| `compaction.bats` | compaction.sh | Constraint supersession, constraint drop rejection, novelty thresholds, JSON append-only, term overlap calculation, trigger precedence |
| `context.bats` | context.sh | 7-section parsing, truncation priority order, mode-sensitive handoff retrieval, knowledge index inlining, budget-per-mode, first-iteration injection |
| `error-handling.bats` | Cross-module | Retry/rollback resilience, interrupted-run behavior, max-retry enforcement |
| `git-ops.bats` | git-ops.sh | Checkpoint/rollback cycle, commit format, ensure clean state, .ralph/ exclusion from cleanup |
| `integration.bats` | ralph.sh | Full orchestrator cycles, state management, validation flow, mode transitions |
| `plan-ops.bats` | plan-ops.sh | Dependency resolution, amendment guardrails (max 3, no done removal, no current task status change), status transitions |
| `progress-log.bats` | progress-log.sh | Entry formatting, deduplication, summary table generation, plan summary counts |
| `telemetry.bats` | telemetry.sh | Event emission, command processing, pause/resume, skip-task, control file lifecycle |
| `validation.bats` | validation.sh | Strategy evaluation, command classification, failure context generation, empty command warning |

### 24.4 Test Fixtures (`tests/fixtures/`)

20 fixture files providing sample data for tests: plans (complete and partial), handoffs (standard, partial, multiple), states (various counter values), knowledge indexes (valid, legacy format, invalid with duplicate active IDs, invalid with missing supersedes targets), mock Claude responses, amendments (valid and invalid).

### 24.5 Test Patterns

- **Temp workspace**: Each test creates `mktemp -d` workspace, tears down on exit
- **Log stubs**: `log() { true; }` silences output
- **Fixture data**: JSON handoffs, plans, and state files created inline
- **Function guards**: `declare -f` used to verify functions are defined
- **Mode parameterization**: Tests run against multiple modes to verify mode-sensitive behavior
- **Dry-run testing**: Tests use `DRY_RUN=true` to verify pipeline without CLI invocation

---

## 25. Screenshot and Dashboard Tooling

**Entry point**: `bash screenshots/capture.sh` or `npm run screenshots`

**Flow**:
1. `capture.sh` auto-detects Playwright + Chromium
2. Builds Tailwind CSS if stale (config at `screenshots/tailwind.config.js`, output at `screenshots/tailwind-generated.css`)
3. Runs `screenshots/take-screenshots.mjs` (Playwright script)

**`take-screenshots.mjs`**:
1. Installs mock data from `screenshots/mock-data/` into live `.ralph/` paths (with `.screenshot-bak` backup)
2. Starts `serve.py` on a configurable port
3. Intercepts Tailwind CDN request via `page.route()` and serves local built CSS
4. Captures 6 views as PNG screenshots at 2x resolution (2880x1800)
5. Restores original files from backups

**Mock data**: 12 handoff files, plan.json, state.json, events.jsonl, knowledge-index.json, progress-log.json — all synthetic data representing a realistic multi-iteration run.

**Environment overrides**: `PLAYWRIGHT_MODULE`, `CHROMIUM_BIN`, `SCREENSHOT_PORT`

**Constraints**:
- External CDN unreachable — Tailwind CSS built locally and injected via `page.route()` intercept
- Chromium requires `--single-process --no-sandbox --disable-gpu --disable-dev-shm-usage` flags
- `tailwind.config.js` content path is `../.ralph/dashboard.html` (relative to `screenshots/` dir)

---

## 26. File System Map

```
project-root/
├── plan.json                                    # Task plan (drives everything)
├── CLAUDE.md                                    # Project conventions (LLM system prompt)
├── SYSTEM.md                                    # This document
├── README.md                                    # Project README
├── package.json                                 # NPM dependencies (Playwright, Tailwind)
│
├── .ralph/
│   ├── ralph.sh                                 # Main orchestrator (1071 lines)
│   ├── serve.py                                 # Dashboard HTTP server (233 lines)
│   ├── dashboard.html                           # Single-file operator dashboard
│   ├── state.json                               # Runtime state (iteration, mode, status, counters)
│   ├── knowledge-index.md                       # Categorized knowledge base (h+i / agent modes)
│   ├── knowledge-index.json                     # Iteration-keyed index for dashboard
│   ├── memory.jsonl                             # Legacy append-only memory (Knowledge Graph MCP)
│   ├── progress-log.md                          # Human-readable progress narrative
│   ├── progress-log.json                        # Machine-readable progress feed
│   │
│   ├── lib/                                     # 9 library modules
│   │   ├── agents.sh                            #   Multi-agent orchestration (808 lines)
│   │   ├── cli-ops.sh                           #   Claude CLI invocation (213 lines)
│   │   ├── compaction.sh                        #   Knowledge indexing + verification (656 lines)
│   │   ├── context.sh                           #   Prompt assembly + truncation (769 lines)
│   │   ├── git-ops.sh                           #   Checkpoint/rollback/commit (85 lines)
│   │   ├── plan-ops.sh                          #   Task selection + plan mutation (312 lines)
│   │   ├── progress-log.sh                      #   Progress log synthesis (420 lines)
│   │   ├── telemetry.sh                         #   Event stream + operator control (230 lines)
│   │   └── validation.sh                        #   Test/lint gate (268 lines)
│   │
│   ├── config/
│   │   ├── ralph.conf                           #   Runtime config (sourced as shell)
│   │   ├── agents.json                          #   Agent pass configuration
│   │   ├── handoff-schema.json                  #   Coding iteration output schema
│   │   ├── context-prep-schema.json             #   Context prep agent output schema
│   │   ├── context-post-schema.json             #   Context post agent output schema
│   │   ├── review-agent-schema.json             #   Code review agent output schema
│   │   ├── memory-output-schema.json            #   Legacy compaction output schema
│   │   ├── mcp-coding.json                      #   MCP config: empty (coding uses built-in tools only)
│   │   ├── mcp-context.json                     #   MCP config: Context7 (library docs)
│   │   └── mcp-memory.json                      #   MCP config: Context7 + Knowledge Graph Memory
│   │
│   ├── templates/
│   │   ├── coding-prompt-footer.md              #   Output instructions (## Output Instructions)
│   │   ├── coding-prompt.md                     #   Reference blueprint (fallback)
│   │   ├── first-iteration.md                   #   Bootstrap context for iteration 1
│   │   ├── context-prep-prompt.md               #   Context agent system prompt (prep)
│   │   ├── context-post-prompt.md               #   Context agent system prompt (post)
│   │   ├── review-agent-prompt.md               #   Code review agent system prompt
│   │   ├── knowledge-index-prompt.md            #   Knowledge indexer instructions
│   │   └── memory-prompt.md                     #   Legacy compaction template
│   │
│   ├── skills/
│   │   ├── bash-conventions.md                  #   Bash coding standards
│   │   ├── git-workflow.md                      #   Git checkpoint/rollback/commit patterns
│   │   ├── jq-patterns.md                       #   jq JSON query recipes
│   │   ├── mcp-config.md                        #   MCP configuration reference
│   │   └── testing-bats.md                      #   bats-core testing patterns
│   │
│   ├── handoffs/                                #   Per-iteration handoff JSON (handoff-001.json, etc.)
│   ├── context/                                 #   Runtime context artifacts
│   │   ├── prepared-prompt.md                   #     Context agent's assembled prompt (agent mode)
│   │   ├── failure-context.md                   #     Validation failure context for retry
│   │   └── compaction-history/                  #     Legacy compaction archives
│   ├── control/
│   │   └── commands.json                        #   Dashboard→orchestrator command queue
│   ├── logs/
│   │   ├── ralph.log                            #   Main log file
│   │   ├── events.jsonl                         #   Append-only telemetry stream
│   │   ├── amendments.log                       #   Plan amendment audit log
│   │   └── validation/                          #   Per-iteration validation results
│   │       └── iter-N.json
│   └── docs/
│
├── tests/
│   ├── test_helper/
│   │   └── common.sh                            #   Shared bats helper
│   ├── fixtures/                                #   20 test fixture files
│   │   ├── sample-plan.json, sample-plan-complete.json
│   │   ├── sample-handoff.json, sample-handoff-002.json, sample-handoff-partial.json
│   │   ├── sample-state.json, sample-state-*.json
│   │   ├── sample-task.json, sample-task-needs-docs.json
│   │   ├── sample-amendments-valid.json, sample-amendments-invalid.json
│   │   ├── sample-compacted-context.json
│   │   ├── mock-claude-response.json
│   │   └── knowledge-index-*.json               #   Valid, legacy, and invalid index fixtures
│   ├── agents.bats
│   ├── cli-ops.bats
│   ├── compaction.bats
│   ├── context.bats
│   ├── error-handling.bats
│   ├── git-ops.bats
│   ├── integration.bats
│   ├── plan-ops.bats
│   ├── progress-log.bats
│   ├── telemetry.bats
│   └── validation.bats
│
├── screenshots/
│   ├── capture.sh                               #   Screenshot entry point
│   ├── take-screenshots.mjs                     #   Playwright script
│   ├── tailwind.config.js                       #   Tailwind CSS config
│   ├── tailwind-generated.css                   #   Built CSS output
│   ├── mock-data/                               #   12 handoffs + supporting mock files
│   └── *.png                                    #   6 dashboard screenshots
│
└── examples/
    └── sample-project-plan.json                 #   Example plan for reference
```

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

---

## 28. Critical Invariants Summary

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
15. **Compaction counter tracking**: Counters reset only after successful verification. Failed indexer runs do NOT reset counters, so the trigger fires again.
16. **No partial fallback data**: `cli-ops.sh` functions return complete, valid JSON or non-zero with only a log message. No corrupt partial output.
17. **Log level hierarchy**: `debug (0) < info (1) < warn (2) < error (3)`. Messages below threshold suppressed. Output to both file and stderr.

---

## 29. Design Patterns Summary

### Atomic Writes
Every JSON mutation (state.json, plan.json, commands.json, ralph.conf) uses **temp-file-then-rename** (`mktemp` → `jq ... > $tmp && mv $tmp $file`). Prevents concurrent readers from seeing partial writes.

### Graceful Degradation
All cross-module function calls guarded with `declare -f function_name >/dev/null 2>&1`. Enables partial-module testing, forward compatibility, and startup robustness.

### Section-Header Coupling
The 7-section prompt headers are parser-sensitive literals used by both `build_coding_prompt_v2()` and `truncate_to_budget()`. Renaming any header breaks truncation.

### Failure Context Lifecycle
Created on validation failure → consumed on next iteration → deleted AFTER successful handoff parse. Deferred deletion prevents loss if retry cycle fails mid-flight.

### Coding Agent Isolation
In all modes, the coding agent runs with `mcp-coding.json` (empty `mcpServers`). Uses only Claude Code's built-in tools (Read, Edit, Bash, Grep, Glob). The context agent or Bash prompt assembly must provide everything upfront.

---

## 30. Execution Examples

### Start a fresh run (handoff-only mode)
```bash
cd /path/to/project
bash .ralph/ralph.sh --plan plan.json --mode handoff-only
```

### Resume an interrupted run
```bash
bash .ralph/ralph.sh --resume
```

### Dry run (validates pipeline without API calls)
```bash
bash .ralph/ralph.sh --dry-run --mode handoff-plus-index
```

### Start the dashboard
```bash
python3 .ralph/serve.py --port 8080
# Dashboard at http://127.0.0.1:8080/.ralph/dashboard.html
```

### Run tests
```bash
bats tests/
```

### Capture dashboard screenshots
```bash
bash screenshots/capture.sh
# or: npm run screenshots
```
