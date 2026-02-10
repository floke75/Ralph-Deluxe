# Ralph Deluxe — Complete System Documentation for LLM Agents

This document provides a complete, self-contained understanding of the Ralph Deluxe system. An LLM reading only this document should be able to reason about every component, data flow, invariant, edge case, and behavioral nuance without examining source code.

---

## 1. What Ralph Deluxe Is

Ralph Deluxe is a **Bash orchestrator** that drives the Claude Code CLI through structured task plans. It automates multi-step software engineering projects by:

1. Reading a `plan.json` file containing ordered, dependency-linked tasks
2. For each task: assembling a context-rich prompt, invoking Claude Code CLI, parsing the structured handoff output, validating the results, and either committing or rolling back
3. Maintaining memory across iterations via handoff narratives (and optionally a knowledge index)
4. Providing a web dashboard for real-time observation and operator control

The core insight: each coding iteration writes a **freeform handoff narrative** that becomes the primary context for the next iteration. This is how the system maintains continuity across what are otherwise stateless LLM calls.

---

## 2. The Three Operating Modes

### 2.1 `handoff-only` (default)

Memory consists entirely of the previous iteration's freeform narrative. No knowledge index, no compaction. The simplest mode — prompt assembly is pure Bash string concatenation.

- **Memory artifact**: Previous handoff's `.freeform` field only
- **Prompt assembly**: `build_coding_prompt_v2()` in `context.sh` (Bash)
- **Token budget**: 8000 tokens (`RALPH_CONTEXT_BUDGET_TOKENS`)
- **Agent calls per iteration**: 1 (coding agent only)
- **Compaction**: None

### 2.2 `handoff-plus-index`

Adds a persistent knowledge index that accumulates constraints, decisions, patterns, and gotchas across all iterations. The knowledge indexer runs periodically (trigger-based) to consolidate handoff data into `.ralph/knowledge-index.md` and `.ralph/knowledge-index.json`.

- **Memory artifacts**: Previous handoff narrative + structured L2 data + full knowledge index inlined in prompt
- **Prompt assembly**: `build_coding_prompt_v2()` in `context.sh` (Bash)
- **Token budget**: 16000 tokens (`RALPH_CONTEXT_BUDGET_TOKENS_HPI`) — double the base to accommodate the inlined index
- **Agent calls per iteration**: 1-2 (coding agent + optional knowledge indexer)
- **Compaction**: Trigger-based via `check_compaction_trigger()` in `compaction.sh`

### 2.3 `agent-orchestrated`

An LLM **context agent** replaces Bash prompt assembly entirely. It reads all available context (handoffs, knowledge index, failure logs, library documentation via MCP tools) and writes a tailored prompt for the coding agent. After coding, it organizes knowledge. Optional agent passes (code review, docs) can run after each iteration.

- **Memory artifacts**: LLM-curated context + knowledge index managed by context agent
- **Prompt assembly**: LLM context agent writes `.ralph/context/prepared-prompt.md`
- **Token budget**: Not Bash-enforced — the context agent uses judgment
- **Agent calls per iteration**: 2-3+ (context prep + coding + context post + optional passes)
- **Compaction**: Every iteration (context post agent handles knowledge organization)

### Mode Priority Resolution

`--mode` CLI flag > `RALPH_MODE` in `ralph.conf` > default `"handoff-only"`

The mode is resolved in `main()` of `ralph.sh`: CLI args are parsed first, then config is loaded, then the priority chain is evaluated. The resolved mode is written to `state.json` so the dashboard and `--resume` can read it.

---

## 3. Architecture: The Complete Data Flow

### 3.1 Startup Phase (`ralph.sh main()`)

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

**Signal handling**: `SIGINT`/`SIGTERM` route through `shutdown_handler()`, which sets `SHUTTING_DOWN=true` (reentrant guard), writes status `"interrupted"` to `state.json`, emits a telemetry event, and exits 130.

### 3.2 Main Loop (one iteration)

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

### 3.3 Terminal States

The loop exits when any of these conditions are met:

| Condition | state.json `status` | Exit behavior |
|-----------|---------------------|---------------|
| All tasks done/skipped | `complete` | Normal exit |
| No runnable tasks (blocked deps) | `blocked` | Normal exit |
| `current_iteration >= MAX_ITERATIONS` | `max_iterations_reached` | Normal exit |
| SIGINT/SIGTERM received | `interrupted` | Exit 130 |
| Operator pause + human review | `paused` | Break from loop |

---

## 4. Module-by-Module Reference

### 4.1 `ralph.sh` — Main Orchestrator (1071 lines)

**Location**: `.ralph/ralph.sh`

**What it owns**: Cross-module sequencing, state transitions, the main loop, CLI argument parsing, config loading, signal handling. It sources all library modules and calls their exported functions.

**Key functions defined here** (not delegated to modules):

| Function | Purpose |
|----------|---------|
| `main()` | Entry point. Parses args, loads config, resolves mode, sources libs, runs main loop |
| `parse_args()` | CLI flag parsing (--mode, --plan, --dry-run, --resume, --max-iterations) |
| `load_config()` | Sources `ralph.conf` as a shell file to set globals |
| `read_state(key)` | Read a single key from `state.json` |
| `write_state(key, value)` | Atomic update of a single key in `state.json` (temp-file-then-rename). Auto-coerces value types (number, bool, null, string) |
| `source_libs()` | Glob-sources all `.ralph/lib/*.sh` files |
| `prepare_skills_file(task_json)` | Bridge between `load_skills()` (returns string) and `run_coding_iteration()` (needs file path). Creates a temp file |
| `build_memory_prompt(compaction_input, task_json)` | Legacy compaction prompt assembly from template + handoff data |
| `run_compaction_cycle(task_json)` | Legacy compaction path (pre-knowledge-index). Kept for backward compatibility |
| `run_agent_coding_cycle(task_json, iteration)` | Agent-orchestrated mode: context prep → coding → signal handling. Returns handoff file path on stdout, directives on stderr |
| `run_coding_cycle(task_json, iteration)` | Handoff-only / handoff-plus-index mode: Bash prompt assembly → coding → parse → save. Returns handoff file path |
| `increment_retry_count(plan_file, task_id)` | Increments `.retry_count` in plan.json for the given task |
| `shutdown_handler()` | SIGINT/SIGTERM handler with reentrant guard |

**Testability guard**: The `main()` call at EOF is wrapped in `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then` so tests can source the file without triggering the loop.

**State file** (`state.json`) schema:
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

### 4.2 `context.sh` — Prompt Assembly and Context Engineering (769 lines)

**Location**: `.ralph/lib/context.sh`

**What it owns**: All prompt construction for handoff-only and handoff-plus-index modes. Token estimation. Section-aware truncation. Knowledge retrieval. Skill loading. In agent-orchestrated mode, it still provides `estimate_tokens()` and `load_skills()`.

**The 7-Section Prompt** (`build_coding_prompt_v2`):

| # | Section Header | Source | When Present | Truncation Priority (1=first removed) |
|---|---------------|--------|-------------|---------------------------------------|
| 1 | `## Current Task` | plan.json task | Always | 7 (last resort — hard truncate) |
| 2 | `## Failure Context` | validation output | Retry only | 6 |
| 3 | `## Retrieved Memory` | Latest handoff constraints + decisions | Always | 5 |
| 4 | `## Previous Handoff` | `get_prev_handoff_for_mode()` or first-iteration.md | Always (content varies) | 3 |
| 5 | `## Retrieved Project Memory` | Full `.ralph/knowledge-index.md` inlined | h+i mode + index exists | 4 |
| 6 | `## Skills` | `.ralph/skills/<name>.md` files | Task has skills[] | 1 (first removed) |
| 7 | `## Output Instructions` | `coding-prompt-footer.md` or inline fallback | Always | 2 |

**Critical invariant**: Section headers must be EXACTLY `## Name` as listed above. The `truncate_to_budget()` awk parser matches these literal strings. Renaming any header silently breaks truncation.

**Key functions**:

| Function | Signature | Purpose |
|----------|-----------|---------|
| `build_coding_prompt_v2` | `(task_json, mode, skills_content, failure_context, first_iteration_context)` | Primary prompt builder. 5th param is optional — on iteration 1, ralph.sh passes `first-iteration.md` content |
| `truncate_to_budget` | `(content, budget_tokens)` | Section-aware truncation. Splits prompt into 7 sections via awk, removes lowest-priority sections iteratively until under budget. Emits `[[TRUNCATION_METADATA]]` JSON to stderr (not included in prompt) |
| `get_prev_handoff_for_mode` | `(handoffs_dir, mode)` | Mode-sensitive handoff retrieval. handoff-only returns `.freeform` only. handoff-plus-index returns freeform + structured L2 (deviations, constraints, decisions) under `### Structured context from previous iteration` |
| `get_budget_for_mode` | `(mode)` | Returns 8000 for handoff-only, 16000 for handoff-plus-index |
| `estimate_tokens` | `(text)` | `chars / 4` — rough heuristic, not billing-accurate |
| `load_skills` | `(task_json, skills_dir)` | Reads `.ralph/skills/<name>.md` for each entry in task's `skills[]` array. Missing skills log a warning but don't fail |
| `retrieve_relevant_knowledge` | `(task_json, index_file, max_lines)` | Keyword-matching against knowledge-index.md. Category-priority sorted. Returns max 12 lines. **Retained for backward compatibility but no longer called by `build_coding_prompt_v2()`** — replaced by full index inlining |
| `_latest_handoff_file` | `(handoffs_dir)` | Resolves latest `handoff-*.json` via find + sort -V. Avoids glob edge cases under `set -e` |

**Mode-sensitive handoff retrieval details**:

- `handoff-only`: Returns `jq '.freeform'` from latest handoff. This IS the sole memory.
- `handoff-plus-index`: Returns freeform + a `### Structured context from previous iteration` subsection containing `{task, decisions, constraints}` JSON extracted from the handoff. The knowledge index handles long-term memory, freeing the handoff to focus on recent tactical context.
- Unknown mode: Logs warning, falls back to handoff-only behavior.

**Truncation algorithm in detail**:

1. If content fits budget → pass through unchanged.
2. Split content into 7 named sections using a single awk pass matching `^## <exact header>$`.
3. Rebuild prompt from sections. While over budget, remove sections in priority order: Skills → Output Instructions → Previous Handoff → Retrieved Project Memory → Retrieved Memory → Failure Context → Current Task (hard truncate as last resort).
4. Emit `[[TRUNCATION_METADATA]]` JSON to stderr with: `truncated_sections` (array of removed section names), `max_chars`, `original_chars`.

**Defensive fallback**: If awk parsing fails to find `## Current Task`, falls back to raw `content[:max_chars]` truncation with a `parser-fallback` metadata tag.

### 4.3 `cli-ops.sh` — Claude Code CLI Invocation (213 lines)

**Location**: `.ralph/lib/cli-ops.sh`

**What it owns**: All direct interaction with the `claude` CLI binary. Builds CLI arguments, executes the binary, captures responses, and extracts handoff JSON from the response envelope.

**Key functions**:

| Function | Purpose |
|----------|---------|
| `run_coding_iteration(prompt, task_json, skills_file)` | Invoke Claude for a coding pass. Reads `.max_turns` from task JSON (default 20). Uses handoff-schema.json + mcp-coding.json. Skills injected via `--append-system-prompt-file`. Prompt piped to stdin |
| `run_memory_iteration(prompt)` | Invoke Claude for memory/indexer pass. Uses memory-output-schema.json + mcp-memory.json. Uses `RALPH_COMPACTION_MAX_TURNS` (default 10) |
| `parse_handoff_output(response)` | Extract `.result` from Claude's response envelope. **Double-parse required**: the outer JSON has `.result` as a JSON-encoded string, not a nested object. Validates inner JSON with `jq .` |
| `save_handoff(handoff_json, iteration)` | Write handoff to `.ralph/handoffs/handoff-NNN.json` (zero-padded). Creates directory if absent. Returns file path on stdout |
| `extract_response_metadata(response)` | Pull `{cost_usd, duration_ms, num_turns, is_error}` from response envelope for telemetry |

**Claude CLI response envelope structure**:
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

Note: `.result` is a **string containing JSON**, not a JSON object. This is why `parse_handoff_output()` must do a double-parse: first extract the string from the envelope, then parse the string as JSON.

**CLI argument construction for coding iterations**:
```bash
claude -p \
  --output-format json \
  --json-schema "$(cat .ralph/config/handoff-schema.json)" \
  --strict-mcp-config \
  --mcp-config .ralph/config/mcp-coding.json \
  --max-turns 20 \
  --dangerously-skip-permissions \           # when RALPH_SKIP_PERMISSIONS=true
  --append-system-prompt-file "$skills_file"  # when skills exist
```

**Dry-run behavior**: Both `run_coding_iteration()` and `run_memory_iteration()` return synthetic valid response envelopes when `DRY_RUN=true`. This exercises the full pipeline without API calls.

**MCP configuration**:
- Coding iterations use `mcp-coding.json` with **empty** `mcpServers` — coding agents use only Claude Code's built-in tools (Read, Edit, Bash, Grep, Glob). No external MCP servers.
- Memory/indexer iterations use `mcp-memory.json` which includes Context7 (library documentation) and the Knowledge Graph Memory Server (cross-session entity/relation storage in `.ralph/memory.jsonl`).
- Context agent (agent-orchestrated mode) uses `mcp-context.json` which includes Context7 only.

### 4.4 `compaction.sh` — Knowledge Indexing and Verification (656 lines)

**Location**: `.ralph/lib/compaction.sh`

**What it owns**: Deciding when to run the knowledge indexer, running it, and verifying the output. Also provides L1/L2/L3 context extraction helpers used by other modules.

#### Compaction Triggers (first match wins)

Evaluated in `check_compaction_trigger(state_file, task_json)`. Each trigger independently returns 0 (fire) or 1 (skip). Precedence:

1. **Task metadata trigger**: Next task has `needs_docs == true` OR `libraries[]` is non-empty. Rationale: the indexer uses MCP tools to fetch library documentation, so it should run before tasks that need external API docs.

2. **Semantic novelty trigger**: Term overlap between the next task's text (title + description + libraries) and recent handoff summaries is below `RALPH_NOVELTY_OVERLAP_THRESHOLD` (default 0.25). This means the next task diverges significantly from recent work, so the knowledge index should be refreshed. The overlap calculation:
   - Tokenize both term sets (lowercase, strip non-alphanumeric, remove words ≤ 2 chars, sort unique)
   - `overlap = |intersection(task_terms, handoff_terms)| / |task_terms|`
   - If overlap < threshold → trigger fires

3. **Byte threshold trigger**: `total_handoff_bytes_since_compaction > RALPH_COMPACTION_THRESHOLD_BYTES` (default 32000, ~8000 tokens). Accumulates compact JSON byte counts from each iteration.

4. **Periodic trigger**: `coding_iterations_since_compaction >= RALPH_COMPACTION_INTERVAL` (default 5).

#### Knowledge Indexer Execution (`run_knowledge_indexer`)

1. `build_compaction_input()` — Aggregate L2 data from all handoffs newer than `last_compaction_iteration`. Each handoff's L2 is extracted via `extract_l2()` and formatted under `--- Iteration N ---` headers.
2. `build_indexer_prompt()` — Combine the knowledge-index-prompt.md template + existing knowledge-index.md + new handoff data.
3. `snapshot_knowledge_indexes()` — Save current `.ralph/knowledge-index.{md,json}` to temp files for rollback. Backup format: first line "1" if file existed, "0" if not.
4. `run_memory_iteration(prompt)` — Claude writes knowledge-index.{md,json} directly via its built-in file tools.
5. `verify_knowledge_indexes()` — Run 4 invariant checks (see below). On failure, `restore_knowledge_indexes()` reverts both files.
6. `update_compaction_state()` — Reset counters: `coding_iterations_since_compaction=0`, `total_handoff_bytes_since_compaction=0`, `last_compaction_iteration=current_iteration`.

#### The Four Verification Checks

All must pass or the indexer's changes are rolled back:

**Check 1: `verify_knowledge_index_header()`**
- File must contain `^# Knowledge Index$` on a line
- File must contain `^Last updated: iteration [0-9]+ \(.+\)$` on a line

**Check 2: `verify_hard_constraints_preserved()`**
- Extract all lines under `## Constraints` in the PREVIOUS index that contain `must`, `must not`, or `never` (case-insensitive)
- Each such line must either: (a) appear identically in the new index, OR (b) have its memory ID referenced in a `[supersedes: K-<type>-<slug>]` tag in the new index, OR (c) appear in a `Superseded: <original line>` legacy format
- Rationale: Hard constraints represent safety-critical decisions. They should never be silently dropped.

**Check 3: `verify_json_append_only()`**
- `knowledge-index.json` must be a JSON array
- If it contains iteration-based records, each must have: `iteration` (number), `task` (string), `summary` (string), `tags` (array)
- Array length must be >= previous length (no entries removed)
- All previous entries must be preserved exactly (deep equality per iteration key)
- No duplicate `iteration` values

**Check 4: `verify_knowledge_index()`**
- No two entries with `status: "active"` (or missing status, which defaults to active) may share the same `memory_id` value
- Every ID referenced in a `supersedes` field must exist as a `memory_id` somewhere in the array

#### L1/L2/L3 Context Extraction

| Level | Function | Output | Size | Used By |
|-------|----------|--------|------|---------|
| L1 | `extract_l1(handoff_file)` | `[TASK-ID] First sentence. Complete\|Partial. N files.` | ~20-50 tokens | `context.sh` for historical summaries |
| L2 | `extract_l2(handoff_file)` | JSON: `{task, decisions, deviations, constraints, failed, unfinished}` | ~200-500 tokens | `build_compaction_input()`, `get_prev_handoff_for_mode()` |
| L3 | `extract_l3(handoff_file)` | File path string | ~10 tokens | Deep-dive reference |

#### Knowledge Index Format

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

### 4.5 `agents.sh` — Multi-Agent Orchestration (808 lines)

**Location**: `.ralph/lib/agents.sh`

**What it owns**: All agent-orchestrated mode logic. Context preparation (pre-coding), knowledge organization (post-coding), and the pluggable agent pass framework.

#### Generic Agent Invocation

`run_agent_iteration(prompt, schema_file, mcp_config, max_turns, model, system_prompt_file)` — unified entry point for all agent types. Constructs CLI args, handles dry-run, returns raw response envelope.

`parse_agent_output(response)` — same double-parse as `parse_handoff_output()` in cli-ops.sh. Extracts `.result` string → re-parses as JSON.

#### Context Preparation (Pre-Coding)

**Purpose**: The context agent reads all available artifacts and writes a self-contained coding prompt. The coding agent receives this prompt and has NO MCP tools — everything it needs must be in the prepared prompt.

**`build_context_prep_input(task_json, iteration, mode)`** builds a lightweight manifest containing:
- Current task details (inlined — small and always needed)
- Task metadata: retry count, max retries, skills, libraries, needs_docs
- File pointers (NOT content): latest handoff path, all handoff count/range, knowledge index paths, failure context path, validation log path, skills directory, templates
- Research requests from previous coding agent's handoff (`request_research` field)
- Human review signals from previous coding agent
- Confidence level from previous coding agent (if not "high")
- State: current iteration, mode, plan file
- Output file path: `.ralph/context/prepared-prompt.md`

**`run_context_prep(task_json, iteration, mode)`**:
1. Build manifest
2. Load system prompt from `context-prep-prompt.md`
3. Delete stale `prepared-prompt.md` so we can detect if agent wrote a new one
4. Invoke context agent with `context-prep-schema.json` + `mcp-context.json`
5. In dry-run: create stub prepared prompt
6. Verify `prepared-prompt.md` exists and is ≥ 50 bytes
7. Return directive JSON

**Context Prep Directives** (from `context-prep-schema.json`):

| Action | Meaning | Orchestrator Response |
|--------|---------|----------------------|
| `proceed` | Coding prompt is ready | Continue to coding phase |
| `skip` | Task should be skipped | Set task status to "skipped", continue loop |
| `request_human_review` | Human judgment needed | Set task to "pending", set status to "paused", break loop |
| `research` | More research needed | Set task to "pending", continue loop (context agent gets another chance) |

**Stuck Detection**: The context prep agent must populate `stuck_detection.is_stuck` (boolean). When true, the orchestrator emits a `stuck_detected` telemetry event with evidence and suggested action.

#### Context Post-Processing (Post-Coding)

**Purpose**: Organize the coding agent's output into accumulated knowledge. Runs after EVERY iteration (including failed validations) because the context agent needs to see failure patterns.

**`build_context_post_input(handoff_file, iteration, task_id, validation_result)`** builds a manifest with:
- Completed iteration details (iteration number, task ID, validation result, handoff path)
- Validation log path (if exists)
- Knowledge index file paths (or "does not exist yet")
- Recent handoff paths (last 5, for pattern detection)
- Verification rules reminder

**`run_context_post(handoff_file, iteration, task_id, validation_result)`**:
1. Build manifest
2. Snapshot existing knowledge indexes (reuses compaction.sh machinery)
3. Invoke context agent with `context-post-schema.json` + `mcp-context.json`
4. Verify knowledge index integrity via `verify_knowledge_indexes()`. On failure, restore snapshots (non-fatal — directive is still returned)
5. Reset compaction counters
6. Return directive JSON (or sensible defaults if parse fails)

**Context Post Directives** (from `context-post-schema.json`):
- `recommended_action`: `proceed`, `skip_task`, `modify_plan`, `request_human_review`, `increase_retries`
- `failure_pattern_detected` / `failure_pattern`: Pattern analysis
- `coding_agent_signals`: Processed research requests, human review, confidence assessment
- These directives are **advisory** — the orchestrator logs them and emits telemetry events, but does not break the loop based on them. They inform the NEXT iteration's context prep pass.

#### Agent Pass Framework

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
- `always` — runs every iteration
- `on_success` — runs only when validation passed
- `on_failure` — runs only when validation failed
- `periodic:N` — runs every N iterations (e.g., `periodic:3` runs on iterations 3, 6, 9...)

**Critical invariant**: Agent passes are NON-FATAL. Failures are logged but never block the main loop. `run_agent_passes()` always returns 0.

**The code review pass** (included as skeleton, disabled by default): Reads the handoff to understand changes, reads `files_touched`, checks for security vulnerabilities, logic errors, convention violations, test coverage gaps. Returns `{review_passed, issues[], summary}`.

### 4.6 `validation.sh` — Post-Iteration Test/Lint Gate (268 lines)

**Location**: `.ralph/lib/validation.sh`

**What it owns**: Running configured validation commands, classifying them, applying strategy to determine pass/fail, generating failure context for retries.

**`run_validation(iteration)`**:
1. Iterate through `RALPH_VALIDATION_COMMANDS` array
2. For each command: `classify_command()` tags it as "test" or "lint"
3. Execute via `eval` (so shell syntax works)
4. Capture stdout+stderr, exit code
5. `evaluate_results()` applies strategy
6. Write results to `.ralph/logs/validation/iter-N.json`
7. Return 0 (pass) or 1 (fail)

**Command classification** (`classify_command`):
- `lint`: matches `shellcheck|lint|eslint|flake8|pylint|stylelint`
- `test`: matches `bats|test|pytest|jest|cargo test|mocha|rspec`
- **Unknown commands default to "test"** (fail-safe — they block progress)

**Strategies** (`evaluate_results`):

| Strategy | Tests must pass? | Lint must pass? |
|----------|------------------|-----------------|
| `strict` (default) | Yes | Yes |
| `lenient` | Yes | No |
| `tests_only` | Yes | No (ignored entirely) |

Note: `lenient` and `tests_only` have identical logic but are kept separate for semantic clarity.

**Empty validation commands**: If `RALPH_VALIDATION_COMMANDS` is empty, validation auto-passes with a warning log. This can silently mask real failures.

**Failure context generation** (`generate_failure_context`):
- Reads `.ralph/logs/validation/iter-N.json`
- Extracts failed checks
- Formats as markdown with `### Validation Failures` header (uses `###` to avoid conflicting with parent `## Failure Context`)
- Truncates each check's output to 500 chars to conserve prompt budget
- Saved to `.ralph/context/failure-context.md` by the caller (ralph.sh)
- **Consumed once**: deleted after successful handoff parse in the next iteration (deferred deletion prevents loss if the retry cycle fails mid-flight)

### 4.7 `plan-ops.sh` — Plan Loading, Task Selection, Plan Mutation (312 lines)

**Location**: `.ralph/lib/plan-ops.sh`

**What it owns**: All plan.json interactions — reading tasks, updating status, applying amendments, checking completion.

**Key functions**:

**`get_next_task(plan_file)`** — Dependency-aware task selection:
- Candidate set: tasks with `status == "pending"`
- A candidate is runnable only when ALL IDs in `depends_on` resolve to tasks with `status == "done"` in the plan
- Selection is deterministic: first runnable task in `.tasks` array order wins
- Returns compact JSON for the task, or empty if nothing is runnable
- Repeated calls without plan mutation return the same task (stable ordering)

**`set_task_status(plan_file, task_id, status)`** — Atomic status update via temp-file-then-rename.

**`apply_amendments(plan_file, handoff_file, current_task_id)`** — Process `plan_amendments[]` from handoff:

Safety guardrails:
- **Max 3 amendments per iteration** — entire batch rejected if exceeded
- **Cannot modify current task's status** — prevents the coding agent from marking itself done
- **Cannot remove tasks with status "done"** — prevents loss of completed work
- Creates `plan.json.bak` before first mutation
- All mutations logged to `.ralph/logs/amendments.log` with timestamps and ACCEPTED/REJECTED status

Amendment operations:
- `add`: Insert a new task. Requires `id`, `title`, `description`. Defaults provided for optional fields (`status: "pending"`, `order: 999`, etc.). Can specify `after` to insert after a specific task ID, otherwise appends.
- `modify`: Merge `changes` object into task by ID. Status changes to the current task are rejected.
- `remove`: Delete task by ID. Tasks with `status: "done"` cannot be removed.
- Invalid individual amendments are skipped; processing continues for remaining items.

**`is_plan_complete(plan_file)`** — Returns 0 if ALL tasks have `status == "done"` or `status == "skipped"`. Note: `failed` tasks do NOT count as complete.

**`count_remaining_tasks(plan_file)`** — Returns count of `pending` + `failed` tasks (does not include `skipped`).

### 4.8 `git-ops.sh` — Transactional Iteration Safety (85 lines)

**Location**: `.ralph/lib/git-ops.sh`

**What it owns**: Git checkpoint/rollback/commit primitives that give each iteration transactional semantics.

**Lifecycle**:
1. `ensure_clean_state()` — at startup, auto-commit dirty working tree so the first rollback has a clean base
2. `create_checkpoint()` → `git rev-parse HEAD` — captures SHA before each coding cycle
3. On failure: `rollback_to_checkpoint(sha)` → `git reset --hard $sha && git clean -fd --exclude=.ralph/`
4. On success: `commit_iteration(iteration, task_id, message)` → `git add -A && git commit -m "ralph[N]: TASK-ID — message"`

**Critical invariant**: `.ralph/` is NEVER cleaned by rollback (`--exclude=.ralph/`). This preserves handoffs, logs, state, and control files across rollbacks.

**Commit format**: `ralph[N]: TASK-ID — description` (configurable prefix via `RALPH_COMMIT_PREFIX`, default "ralph").

**Assumptions**: Iteration commits are local, linear commits. This module does not rebase, merge, or resolve conflicts. Conflict handling is delegated to higher-level orchestration or user workflow.

### 4.9 `telemetry.sh` — Event Stream and Operator Control (230 lines)

**Location**: `.ralph/lib/telemetry.sh`

**What it owns**: Append-only event logging (JSONL) and the operator command queue (dashboard → orchestrator control plane).

**Event Stream** (`.ralph/logs/events.jsonl`):

Each line is a compact JSON object:
```json
{"timestamp":"2026-02-07T14:30:00Z","event":"iteration_start","message":"Starting iteration 5","metadata":{"iteration":5,"task_id":"TASK-003","task_title":"Git operations module"}}
```

Event types: `orchestrator_start`, `orchestrator_end`, `iteration_start`, `iteration_end`, `validation_pass`, `validation_fail`, `pause`, `resume`, `note`, `skip_task`, `stuck_detected`, `failure_pattern`, `human_review_requested`, `agent_pass`.

No fsync forced — durability is OS-buffered best effort. Consumers should treat newest lines as eventually durable.

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

**Delivery semantics**: At-least-once best effort. Commands may be replayed if a crash happens after execution but before `clear_pending_commands()`.

**Stale/unknown commands**: Treated as idempotent or ignored. Pause while already paused is a no-op state-set. Unknown command keys are logged and skipped.

### 4.10 `progress-log.sh` — Synthesized Progress Logs (420 lines)

**Location**: `.ralph/lib/progress-log.sh`

**What it owns**: Maintaining two coordinated progress artifacts — a human/LLM-readable markdown file and a machine-readable JSON file.

**Why it exists**: Raw handoffs are per-iteration and not query-friendly. Plan state alone lacks per-iteration rationale. The progress log merges both: accountability (what changed, why) + status observability (where each task stands).

**Two output files**:

1. **`.ralph/progress-log.md`** — markdown with:
   - Header (title, plan name)
   - Summary table (task | status | summary) — rebuilt from plan.json each time
   - `---` separator
   - Per-iteration `### TASK-ID: Title (Iteration N)` blocks with: summary, files changed table, tests added, design decisions, constraints, deviations, bugs

2. **`.ralph/progress-log.json`** — JSON with:
   ```json
   {
     "generated_at": "2026-02-07T14:30:00Z",
     "plan_summary": {"total_tasks": 12, "completed": 3, "pending": 8, "failed": 1, "skipped": 0},
     "entries": [{"task_id": "TASK-002", "iteration": 3, "summary": "...", "files_changed": [...], ...}]
   }
   ```

**`append_progress_entry(handoff_file, iteration, task_id)`**:
- Deduplicates by `(task_id, iteration)` in JSON
- Refreshes `generated_at` and `plan_summary` counts
- Regenerates the full markdown file (so summary table always reflects latest task statuses)
- Called by ralph.sh step 6b, after validation pass, before amendments

**Task title resolution**: Uses `get_task_by_id()` from plan-ops.sh (guarded with `declare -f`). Falls back to using task_id as the title if plan-ops.sh isn't available.

---

## 5. The Handoff Schema — What the Coding Agent Produces

Every coding iteration must output JSON matching `handoff-schema.json`. This is the primary artifact that carries context between iterations.

### Required Fields

| Field | Type | Purpose |
|-------|------|---------|
| `summary` | string | One-line description of what was accomplished |
| `freeform` | string (min 50 chars) | **The most important field.** Narrative briefing for the next iteration — what was done, why, surprises, fragile areas, recommendations |
| `task_completed` | object | `{task_id, summary, fully_complete}` |
| `deviations` | array | `[{planned, actual, reason}]` — where implementation diverged from plan |
| `bugs_encountered` | array | `[{description, resolution, resolved}]` |
| `architectural_notes` | array of strings | Design decisions made |
| `unfinished_business` | array | `[{item, reason, priority}]` — priority enum: high/medium/low |
| `recommendations` | array of strings | Suggestions for next steps |
| `files_touched` | array | `[{path, action}]` — action enum: created/modified/deleted |
| `plan_amendments` | array | `[{action, task_id, task, changes, after, reason}]` — action enum: add/modify/remove |
| `tests_added` | array | `[{file, test_names}]` |
| `constraints_discovered` | array | `[{constraint, impact, workaround?}]` |

### Signal Fields (agent-orchestrated mode)

| Field | Type | Purpose |
|-------|------|---------|
| `request_research` | string[] | Topics for the context agent to research next iteration |
| `request_human_review` | `{needed: bool, reason?: string}` | Signal that human judgment is needed |
| `confidence_level` | enum: high/medium/low | Self-assessed output confidence |

These signal fields enable a feedback loop: the coding agent tells the context agent what it needs, and the context agent provides it in the next iteration's prompt.

---

## 6. The Plan (`plan.json`) — What Drives Everything

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
      "acceptance_criteria": ["All directories from the spec exist", "..."],
      "depends_on": [],
      "max_turns": 15,
      "retry_count": 0,
      "max_retries": 2
    }
  ]
}
```

**Task status lifecycle**: `pending` → `in_progress` → `done` | `failed` | `skipped`

**Dependency resolution**: `depends_on` contains task IDs. A task is only runnable when ALL listed dependencies have `status == "done"`. Tasks with unmet dependencies are silently skipped by `get_next_task()` and picked up in later iterations when dependencies complete.

**Retry mechanics**: `retry_count` is incremented on each failure. When `retry_count >= max_retries` (default 2), the task is marked `failed`. Retries are tracked per-task in plan.json (not in state.json) because retries are task-specific.

**Skills injection**: The `skills[]` array maps to files in `.ralph/skills/<name>.md`. These are concatenated and injected into the `## Skills` section of the coding prompt.

**Library documentation**: When `needs_docs == true` or `libraries[]` is non-empty, the compaction trigger fires to fetch documentation via Context7 MCP.

---

## 7. The Skill System

Skills are markdown files in `.ralph/skills/` that provide coding conventions and tool usage reference. They are injected into the prompt's `## Skills` section when a task's `skills[]` array references them.

| Skill File | Content |
|-----------|---------|
| `bash-conventions.md` | Script headers, variable naming, conditionals, error handling, logging, function style |
| `git-workflow.md` | Checkpoint/rollback/commit patterns, commit message format, rules (never force push, etc.) |
| `jq-patterns.md` | Reusable jq recipes for plan/handoff/state JSON operations, safe in-place update pattern |
| `testing-bats.md` | bats-core test syntax, `run` command, setup/teardown, assertions without bats-assert |
| `mcp-config.md` | MCP strict mode, config file selection, Context7 two-step usage, Knowledge Graph Memory Server tools |

Skills are loaded by `load_skills()` in context.sh. Missing skill files log a warning but don't fail prompt assembly.

---

## 8. The Dashboard and HTTP Server

### 8.1 `serve.py` — HTTP Bridge (233 lines)

**Location**: `.ralph/serve.py`

A Python HTTP server that bridges the dashboard UI and Ralph's file-based control plane.

**Endpoints**:

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/*` | Serve static files from project root (dashboard, state.json, plan.json, handoffs/, events.jsonl, progress-log.json) |
| POST | `/api/command` | Accept command object, append to `commands.json` `pending[]` |
| POST | `/api/settings` | Accept settings update, apply whitelisted keys to `ralph.conf` |
| OPTIONS | `*` | CORS preflight (dashboard may run on a different port) |

**Settings whitelist** (only these can be changed from the dashboard):
- `RALPH_VALIDATION_STRATEGY`, `RALPH_COMPACTION_INTERVAL`, `RALPH_COMPACTION_THRESHOLD_BYTES`, `RALPH_DEFAULT_MAX_TURNS`, `RALPH_MIN_DELAY_SECONDS`, `RALPH_MODE`

**Security**: Values are sanitized to match `^[a-zA-Z0-9_-]+$` — rejects anything that could inject shell syntax. All writes use `atomic_write()` (temp-file-then-`os.replace()`).

**Startup**: `python3 .ralph/serve.py --port 8080 --bind 127.0.0.1`

### 8.2 `dashboard.html` — Operator Dashboard

**Location**: `.ralph/dashboard.html`

Single-file vanilla JavaScript + Tailwind CSS dashboard. Polls server every 3 seconds for state updates.

**Views** (6 screenshot captures exist):
1. Main dashboard — iteration status, task progress, cost tracking
2. Handoff detail — expanded view of individual handoff content
3. Handoff-only mode view
4. Architecture tab — system overview
5. Progress log detail — per-task execution history
6. Settings panel — runtime configuration controls

---

## 9. Configuration Reference

### 9.1 `ralph.conf` — Runtime Configuration

**Location**: `.ralph/config/ralph.conf`

This is a **shell file** sourced directly by `load_config()`. Variables become globals.

| Variable | Default | Module | Purpose |
|----------|---------|--------|---------|
| `RALPH_MAX_ITERATIONS` | 50 | ralph.sh | Maximum iterations before forced stop |
| `RALPH_PLAN_FILE` | `plan.json` | ralph.sh | Path to plan file |
| `RALPH_VALIDATION_STRATEGY` | `strict` | validation.sh | `strict` / `lenient` / `tests_only` |
| `RALPH_MODE` | `handoff-only` | ralph.sh | Operating mode |
| `RALPH_COMPACTION_INTERVAL` | 5 | compaction.sh | Iterations between periodic indexer runs |
| `RALPH_COMPACTION_THRESHOLD_BYTES` | 32000 | compaction.sh | Byte threshold for indexer trigger |
| `RALPH_COMPACTION_MAX_TURNS` | 10 | cli-ops.sh | Max turns for memory/indexer CLI calls |
| `RALPH_DEFAULT_MAX_TURNS` | 20 | cli-ops.sh | Default max turns for coding iterations |
| `RALPH_MIN_DELAY_SECONDS` | 30 | ralph.sh | Rate limit delay between iterations |
| `RALPH_CONTEXT_BUDGET_TOKENS` | 8000 | context.sh | Token budget for handoff-only mode |
| `RALPH_CONTEXT_BUDGET_TOKENS_HPI` | 16000 | context.sh | Token budget for handoff-plus-index mode |
| `RALPH_MODEL` | `""` (default) | cli-ops.sh | Model override (empty = default) |
| `RALPH_FALLBACK_MODEL` | `sonnet` | cli-ops.sh | Fallback model |
| `RALPH_SKIP_PERMISSIONS` | `true` | cli-ops.sh, agents.sh | Pass `--dangerously-skip-permissions` to claude CLI |
| `RALPH_AUTO_COMMIT` | `true` | git-ops.sh | Auto-commit on successful validation |
| `RALPH_COMMIT_PREFIX` | `ralph` | git-ops.sh | Prefix for commit messages |
| `RALPH_CONTEXT_AGENT_MODEL` | `""` | agents.sh | Model override for context agent |
| `RALPH_AGENT_PASSES_ENABLED` | `true` | agents.sh | Enable/disable optional agent passes |
| `RALPH_LOG_LEVEL` | `info` | ralph.sh | `debug` / `info` / `warn` / `error` |
| `RALPH_LOG_FILE` | `.ralph/logs/ralph.log` | ralph.sh | Log file path |
| `RALPH_VALIDATION_COMMANDS` | (array) | validation.sh | Shell commands to run for validation |

### 9.2 `agents.json` — Agent Pass Configuration

**Location**: `.ralph/config/agents.json`

```json
{
  "context_agent": {
    "model": null,
    "prep": { "max_turns": 10, "prompt_template": "context-prep-prompt.md", "schema": "context-prep-schema.json", "mcp_config": "mcp-context.json", "output_file": ".ralph/context/prepared-prompt.md" },
    "post": { "max_turns": 10, "prompt_template": "context-post-prompt.md", "schema": "context-post-schema.json", "mcp_config": "mcp-context.json" }
  },
  "passes": [
    { "name": "review", "enabled": false, "model": "haiku", "trigger": "on_success", "max_turns": 5, "prompt_template": "review-agent-prompt.md", "schema": "review-agent-schema.json", "mcp_config": "mcp-coding.json", "read_only": true }
  ]
}
```

---

## 10. All JSON Schemas

### 10.1 Handoff Schema (`handoff-schema.json`)

Required output from every coding iteration. Fields documented in Section 5.

### 10.2 Context Prep Schema (`context-prep-schema.json`)

Output from context preparation agent:
- `action` (required): enum `proceed` / `skip` / `request_human_review` / `research`
- `reason` (required): string explaining the action
- `stuck_detection` (required): `{is_stuck: bool, evidence?: string, suggested_action?: string}`
- `prompt_token_estimate`: approximate token count of prepared prompt
- `sections_included`: which prompt sections were included
- `context_notes`: internal reasoning (logged but not acted upon)

### 10.3 Context Post Schema (`context-post-schema.json`)

Output from knowledge organization agent:
- `knowledge_updated` (required): boolean
- `recommended_action` (required): enum `proceed` / `skip_task` / `modify_plan` / `request_human_review` / `increase_retries`
- `summary` (required): one-line summary
- `failure_pattern_detected`: boolean
- `failure_pattern`: description of detected pattern
- `plan_suggestions`: array of `{action, task_id, reason}`
- `coding_agent_signals`: `{research_requests: string[], human_review_requested: bool, confidence_assessment: enum}`

### 10.4 Review Agent Schema (`review-agent-schema.json`)

Output from code review agent pass:
- `review_passed` (required): boolean
- `issues` (required): array of `{severity: critical/warning/suggestion, file?: string, description, suggested_fix?: string}`
- `summary` (required): string

### 10.5 Memory Output Schema (`memory-output-schema.json`)

Legacy compaction output:
- `project_summary` (required): string
- `completed_work` (required): string[]
- `active_constraints` (required): array of `{constraint, source_iteration?}`
- `architectural_decisions` (required): string[]
- `file_knowledge` (required): array of `{path, purpose}`
- `unresolved_issues`: string[]
- `library_docs`: array of `{library, key_apis, usage_notes?}`

---

## 11. Error Handling, Retry, and Rollback

### 11.1 Coding Cycle Failure

When `run_coding_cycle()` or `run_agent_coding_cycle()` returns non-zero:

1. **Agent directive check** (agent-orchestrated only): stderr is checked for `DIRECTIVE:skip`, `DIRECTIVE:request_human_review`, `DIRECTIVE:research`. These are NOT coding failures — they're context agent recommendations.
2. `rollback_to_checkpoint()` — hard reset to pre-iteration SHA + clean untracked files (excluding `.ralph/`)
3. `increment_retry_count()` — increment task's retry count in plan.json
4. If `retry_count >= max_retries` → `set_task_status("failed")`
5. Task stays/returns to `pending` (or `failed`) and the loop continues

### 11.2 Validation Failure

When `run_validation()` returns 1:

1. `rollback_to_checkpoint()` — same as above
2. `increment_retry_count()` — same as above
3. `generate_failure_context()` → saves to `.ralph/context/failure-context.md`
4. On next iteration of the same task, failure context is injected into `## Failure Context` section
5. **Failure context lifecycle**: Created on validation failure → read on next attempt → deleted after successful handoff parse (deferred deletion prevents loss if the retry cycle fails mid-flight)

### 11.3 Knowledge Index Verification Failure

When `verify_knowledge_indexes()` returns 1:

1. `restore_knowledge_indexes()` reverts both `.ralph/knowledge-index.{md,json}` from snapshots
2. Compaction counters are NOT reset (so the trigger will fire again)
3. The main loop continues — knowledge index verification failure is non-fatal

### 11.4 Agent Pass Failure

Always non-fatal. Logged but does not block the main loop. `run_agent_passes()` always returns 0.

### 11.5 Graceful Shutdown

`SIGINT`/`SIGTERM` → `shutdown_handler()`:
1. Reentrant guard: if `SHUTTING_DOWN=true`, return immediately
2. Set `SHUTTING_DOWN=true`
3. Emit `orchestrator_end` event (if telemetry is available)
4. Write `status: "interrupted"` to state.json
5. Exit 130

The main loop checks `SHUTTING_DOWN` at the top of each iteration for cooperative shutdown.

### 11.6 Resume

`--resume` flag: reads `current_iteration` from state.json and continues from there. Without `--resume`, iteration resets to 0 and status is set to "running".

---

## 12. Cross-Module Function Dependencies

This is a complete call graph showing which functions call which across module boundaries.

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

All cross-module function calls are guarded with `declare -f function_name >/dev/null 2>&1` for graceful degradation when modules are missing or testing in isolation.

---

## 13. Prompt Templates

### 13.1 `coding-prompt-footer.md` — Output Instructions

Loaded into `## Output Instructions` section. Tells the coding agent:
- Produce valid JSON matching the handoff schema
- `summary`: one sentence
- `freeform`: the most important field — write as if briefing a colleague. Cover: what you did and why, surprises, fragile areas, recommendations, key technical details
- Structured fields help the orchestrator track progress; freeform narrative is how the next iteration understands what happened

### 13.2 `first-iteration.md` — Bootstrap Context

Injected into `## Previous Handoff` on iteration 1 (when no prior handoffs exist):
- Signals this is a clean slate — no prior decisions, no constraints, no history
- Emphasizes that conventions established now carry forward
- Stresses the importance of thorough handoff documentation since it seeds all future context

### 13.3 `context-prep-prompt.md` — Context Agent System Prompt

System prompt for the context preparation agent. Core principle: **the coding agent should never have to research anything**. Key responsibilities:
1. Research library docs via Context7 MCP
2. Analyze handoffs, knowledge index, failure context
3. Detect stuck patterns (2+ retries with same failure)
4. Write self-contained prompt with exact 7-section headers
5. Return directive (proceed/skip/review/research)

Guidelines: clarity over brevity, research first, pre-digest everything (don't link — inline), synthesize don't dump, highlight risks, preserve hard constraints, first iteration special case.

### 13.4 `context-post-prompt.md` — Knowledge Organization Agent System Prompt

System prompt for the post-coding knowledge agent. Responsibilities:
1. Update knowledge-index.{md,json} following the memory ID format
2. Detect failure patterns across recent iterations
3. Process coding agent signals (research requests, confidence, human review)
4. Return recommendations

Verification rules are embedded: header format, hard constraint preservation, JSON append-only, ID consistency.

### 13.5 `review-agent-prompt.md` — Code Review Agent System Prompt

READ-ONLY agent. Checks for: security vulnerabilities, logic errors, missing error handling, convention violations, test coverage gaps. Does NOT flag: style preferences, minor formatting, theoretical edge cases.

### 13.6 `knowledge-index-prompt.md` — Knowledge Indexer Instructions

Instructions for the periodic knowledge indexer (h+i mode). Covers both output file formats, entry format with stable memory IDs, and all 4 verification rules the output must pass.

### 13.7 `memory-prompt.md` — Legacy Compaction Template

Legacy template for the v1 compaction system. Instructions to deduplicate decisions, preserve constraints, summarize completed work, build file knowledge, query library docs via Context7, persist to Knowledge Graph.

---

## 14. Testing Infrastructure

### 14.1 Framework

**Framework**: bats-core. Test files in `tests/*.bats`. Each module has its own test file.

### 14.2 Test Helper (`tests/test_helper/common.sh`)

Shared helper sourced by all test suites. Provides:

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

### 14.3 Test Files and Coverage

| Test File | Module Under Test | Key Coverage |
|-----------|-------------------|-------------|
| `agents.bats` | agents.sh | Context prep/post input building, directive handling, pass triggers, agent config loading, dry-run flows, handoff signal fields |
| `context.bats` | context.sh | 7-section parsing, truncation priority order, mode-sensitive handoff retrieval, knowledge index inlining, budget-per-mode, first-iteration injection |
| `compaction.bats` | compaction.sh | Constraint supersession, constraint drop rejection, novelty thresholds, JSON append-only, term overlap calculation, trigger precedence |
| `plan-ops.bats` | plan-ops.sh | Dependency resolution, amendment guardrails (max 3, no done removal, no current task status change), status transitions |
| `cli-ops.bats` | cli-ops.sh | Response parsing, double-parse validation, dry-run responses, handoff saving |
| `git-ops.bats` | git-ops.sh | Checkpoint/rollback cycle, commit format, ensure clean state, .ralph/ exclusion from cleanup |
| `integration.bats` | ralph.sh (full system) | Full orchestrator cycles, state management, validation flow, mode transitions |
| `validation.bats` | validation.sh | Strategy evaluation, command classification, failure context generation, empty command warning |
| `telemetry.bats` | telemetry.sh | Event emission, command processing, pause/resume, skip-task, control file lifecycle |
| `progress-log.bats` | progress-log.sh | Entry formatting, deduplication, summary table generation, plan summary counts |
| `error-handling.bats` | Cross-module | Retry/rollback resilience, interrupted-run behavior, max-retry enforcement |

### 14.4 Test Fixtures (`tests/fixtures/`)

20 fixture files providing sample data for tests: plans (complete and partial), handoffs (standard, partial, multiple), states (various counter values), knowledge indexes (valid, legacy format, invalid with duplicate active IDs, invalid with missing supersedes targets), mock Claude responses, amendments (valid and invalid).

---

## 15. Screenshot and Dashboard Tooling

### 15.1 Screenshot Capture Pipeline

**Entry point**: `bash screenshots/capture.sh` or `npm run screenshots`

**Flow**:
1. `capture.sh` auto-detects Playwright + Chromium
2. Builds Tailwind CSS if stale (config at `screenshots/tailwind.config.js`, output at `screenshots/tailwind-generated.css`)
3. Runs `screenshots/take-screenshots.mjs` (Playwright script)

**`take-screenshots.mjs`**:
1. Installs mock data from `screenshots/mock-data/` into live `.ralph/` paths (with `.screenshot-bak` backup)
2. Starts `serve.py` on a configurable port
3. Intercepts Tailwind CDN request via `page.route()` and serves local built CSS
4. Captures 6 views as PNG screenshots
5. Restores original files from backups

**Mock data**: 12 handoff files, plan.json, state.json, events.jsonl, knowledge-index.json, progress-log.json — all synthetic data representing a realistic multi-iteration run.

**Environment overrides**: `PLAYWRIGHT_MODULE`, `CHROMIUM_BIN`, `SCREENSHOT_PORT`

**Constraints**:
- External CDN unreachable — Tailwind CSS built locally and injected via `page.route()` intercept
- Chromium requires `--single-process --no-sandbox --disable-gpu --disable-dev-shm-usage` flags
- `tailwind.config.js` content path is `../.ralph/dashboard.html` (relative to screenshots/ dir)

---

## 16. File System Map

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
│   │   ├── coding-prompt.md                     #   Reference blueprint (not read at runtime)
│   │   ├── coding-prompt-footer.md              #   Output instructions (## Output Instructions)
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
│       └── documentation-update-plan.md
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

## 17. Design Patterns and Invariants Summary

### Atomic Writes
Every JSON mutation (state.json, plan.json, commands.json, ralph.conf) uses **temp-file-then-rename** (`mktemp` → `jq ... > $tmp && mv $tmp $file`). This prevents concurrent readers (dashboard, orchestrator) from seeing partial writes.

### Graceful Degradation
All cross-module function calls are guarded with `declare -f function_name >/dev/null 2>&1`. This enables:
- Partial-module testing (source one module without the others)
- Forward compatibility (new functions in newer modules don't break older callers)
- Startup robustness (signal handlers work even if telemetry isn't sourced yet)

### Section-Header Coupling
The 7-section prompt headers (`## Current Task`, `## Failure Context`, etc.) are parser-sensitive literals used by both `build_coding_prompt_v2()` and `truncate_to_budget()`. Renaming any header breaks truncation.

### Failure Context Lifecycle
Created on validation failure → consumed on next iteration → deleted AFTER successful handoff parse (not before). This deferred deletion prevents loss if the retry cycle fails mid-flight.

### No Partial Fallback Data
`cli-ops.sh` functions avoid emitting partial handoff payloads on failure. They either return complete, valid JSON or return non-zero with only a log message. This lets callers safely retry without checking for corrupt output.

### Compaction Counter Tracking
Compaction trigger counters (`total_handoff_bytes_since_compaction`, `coding_iterations_since_compaction`) accumulate in state.json. They're reset only after successful verification of the knowledge indexer's output. Failed indexer runs do NOT reset counters, so the trigger fires again.

### Coding Agent Has No MCP Tools
In all modes, the coding agent runs with `mcp-coding.json` which has empty `mcpServers`. The coding agent uses only Claude Code's built-in tools (Read, Edit, Bash, Grep, Glob). This is by design — the context agent (or Bash prompt assembly) must provide everything the coding agent needs upfront.

### Log Level Hierarchy
`debug (0) < info (1) < warn (2) < error (3)`. Messages below the configured `RALPH_LOG_LEVEL` threshold are suppressed. All log output goes to both file and stderr.

---

## 18. Execution Examples

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
