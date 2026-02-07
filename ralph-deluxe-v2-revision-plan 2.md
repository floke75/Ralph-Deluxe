# Ralph-Deluxe v2: Revision Plan

**This is a modification plan for the existing codebase at github.com/floke75/Ralph-Deluxe, not a greenfield design.**

The repo already has a working ~350-line orchestrator, six lib modules (cli-ops, compaction, context, git-ops, plan-ops, validation), a test suite, five skill files, and templates. The v2 revision adds two things and refactors one:

1. **Add** a freeform handoff narrative to the output schema (the lost core idea)
2. **Add** a dashboard with telemetry + control plane
3. **Refactor** the compaction system into a selectable knowledge indexer mode

Everything else stays. Git-ops, validation, plan-ops, skills injection, plan mutation — all proven, all keep working.

---

## What exists today (inventory)

```
.ralph/
├── ralph.sh                     # Main loop (~350 lines) ✓ keep
├── lib/
│   ├── cli-ops.sh               # claude -p wrappers ✓ modify (add mode flag)
│   ├── compaction.sh            # L1/L2/L3 extraction ✓ refactor → knowledge indexer
│   ├── context.sh               # Prompt assembly ✓ modify (handoff-first mode)
│   ├── git-ops.sh               # Checkpoint/rollback ✓ keep as-is
│   ├── plan-ops.sh              # Task read/mutate ✓ keep as-is
│   └── validation.sh            # Test/lint gates ✓ keep as-is
├── config/
│   ├── handoff-schema.json      # 8 required fields ✓ modify (add summary + freeform)
│   ├── mcp-coding.json          # Empty MCP config ✓ keep
│   ├── mcp-memory.json          # Context7 + KG Memory ✓ keep (knowledge mode only)
│   ├── memory-output-schema.json # Compaction output schema ✓ keep (knowledge mode)
│   └── ralph.conf               # Settings ✓ modify (add mode, dashboard settings)
├── skills/                      # 5 skill files ✓ keep as-is
├── templates/
│   ├── coding-prompt.md         # Prompt template ✓ modify (handoff framing)
│   ├── memory-prompt.md         # Compaction prompt ✓ refactor → indexer prompt
│   └── first-iteration.md       # Bootstrap prompt ✓ keep
├── state.json                   # Runtime state ✓ modify (add mode field)
└── memory.jsonl                 # KG Memory data ✓ keep (knowledge mode)

plan.json                        # Task plan ✓ keep as-is
tests/                           # bats suite ✓ extend
CLAUDE.md                        # Project conventions ✓ update
README.md                        # Documentation ✓ update
```

---

## Change 1: The handoff narrative

### Problem

The current handoff schema has 8 required structured fields. The coding LLM fills them out like a form. The freeform synthesis — "write a handoff for whoever picks this up next" — doesn't exist. The most valuable artifact (the LLM's own oriented briefing) is missing.

### Solution

Add two fields to `handoff-schema.json`: `summary` (string, required) and `freeform` (string, required).

`summary` is a one-line description of what was done (used by the orchestrator for logging, metrics, and the knowledge index). `freeform` is the full handoff narrative — the LLM's oriented briefing for the next iteration.

#### Modified schema: `.ralph/config/handoff-schema.json`

Add to `properties`:
```json
"summary": {
  "type": "string",
  "description": "One-line summary of what was accomplished this iteration."
},
"freeform": {
  "type": "string",
  "description": "Freeform handoff briefing for the next iteration. Write as if briefing a colleague picking up the work tomorrow."
}
```

Add `"summary"` and `"freeform"` to the `required` array.

The existing structured fields stay — they're useful for orchestrator bookkeeping. But the narrative becomes the primary artifact that travels forward.

#### Modified template: `.ralph/templates/coding-prompt.md`

Current "Output Requirements" section:
```
## Output Requirements
You MUST produce a handoff document as your final output. Structure your response
as valid JSON matching the handoff schema provided via --json-schema.
After implementing, run the acceptance criteria checks yourself before producing
the handoff.

Key fields in the handoff:
- task_completed: summary of what you did...
[etc.]
```

Replace with:
```
## When You're Done

After completing your implementation and verifying the acceptance criteria,
write a handoff for whoever picks up this project next.

Your output must be valid JSON matching the provided schema.

The `summary` field should be a single sentence describing what you accomplished.

The `freeform` field is the most important part of your output — write it as
if briefing a colleague who's picking up tomorrow. Cover:

- What you did and why you made the choices you made
- Anything that surprised you or didn't go as expected
- Anything that's fragile, incomplete, or needs attention
- What you'd recommend the next iteration focus on
- Key technical details the next person needs to know

The structured fields (task_completed, files_touched, etc.) help the
orchestrator track progress. The freeform narrative is how the next
iteration will actually understand what happened.
```

#### Modified context: `.ralph/lib/context.sh`

The `get_prev_handoff_summary()` function currently extracts L2 (structured decisions/constraints). In handoff-only mode, it should instead return the `freeform` field:

```bash
get_prev_handoff_for_mode() {
    local handoffs_dir="${1:-.ralph/handoffs}"
    local mode="${2:-handoff-only}"

    local latest
    latest=$(ls -1 "${handoffs_dir}"/handoff-*.json 2>/dev/null | sort -V | tail -1)

    if [[ -z "$latest" ]]; then
        echo ""
        return
    fi

    case "$mode" in
        handoff-only)
            # Return the full freeform narrative — this IS the memory
            jq -r '.freeform // empty' "$latest"
            ;;
        handoff-plus-index)
            # Return freeform + structured L2 for richer context
            local narrative
            narrative=$(jq -r '.freeform // ""' "$latest")
            local l2
            l2=$(jq -r '{
                task: .task_completed.task_id,
                decisions: .architectural_notes,
                constraints: [.constraints_discovered[] | "\(.constraint): \(.workaround // .impact)"]
            }' "$latest")
            echo "${narrative}"
            echo ""
            echo "### Structured context from previous iteration"
            echo "${l2}"
            ;;
    esac
}
```

The existing `get_prev_handoff_summary()` stays for backward compatibility. The new function is used by the mode-aware prompt assembly.

---

## Change 2: Selectable mode

### The `--mode` flag

Add to `ralph.sh` argument parsing:

```bash
MODE="${RALPH_MODE:-handoff-only}"  # handoff-only | handoff-plus-index

# In parse_args():
--mode)
    MODE="$2"
    shift 2
    ;;
```

Add to `ralph.conf`:
```bash
RALPH_MODE="handoff-only"   # handoff-only | handoff-plus-index
```

### How mode affects the loop

In `ralph.sh` main loop, the existing compaction check:

```bash
# Step 1: Check compaction trigger
if check_compaction_trigger "$STATE_FILE" "$task_json"; then
    log "info" "Compaction triggered, running memory iteration"
    run_compaction_cycle "$task_json" || { ... }
fi
```

Becomes:

```bash
# Step 1: Check if knowledge indexing is due (handoff-plus-index mode only)
if [[ "$MODE" == "handoff-plus-index" ]]; then
    if check_compaction_trigger "$STATE_FILE" "$task_json"; then
        log "info" "Knowledge indexing triggered"
        run_knowledge_indexer "$task_json" || {
            log "warn" "Knowledge indexing failed, continuing"
        }
    fi
fi
```

### How mode affects prompt assembly

The `build_coding_prompt()` in `context.sh` currently injects compacted context. Mode-aware version:

```bash
build_coding_prompt_v2() {
    local task_json="$1"
    local mode="${2:-handoff-only}"
    local skills_content="$3"
    local failure_context="$4"

    local handoffs_dir=".ralph/handoffs"
    local prompt=""

    # === TASK (always) ===
    prompt+="## Current Task"$'\n'
    prompt+="$(format_task_section "$task_json")"$'\n\n'

    # === FAILURE CONTEXT (if retrying) ===
    if [[ -n "$failure_context" ]]; then
        prompt+="## Previous Attempt Failed"$'\n'
        prompt+="$failure_context"$'\n\n'
    fi

    # === PREVIOUS HANDOFF (always — this is the core) ===
    local prev_handoff
    prev_handoff="$(get_prev_handoff_for_mode "$handoffs_dir" "$mode")"
    if [[ -n "$prev_handoff" ]]; then
        prompt+="## Handoff from Previous Iteration"$'\n'
        prompt+="$prev_handoff"$'\n\n'
    else
        prompt+="## Context"$'\n'
        prompt+="This is the first iteration. No previous handoff available."$'\n\n'
    fi

    # === KNOWLEDGE INDEX POINTER (handoff-plus-index mode only) ===
    if [[ "$mode" == "handoff-plus-index" && -f ".ralph/knowledge-index.md" ]]; then
        prompt+="## Accumulated Knowledge"$'\n'
        prompt+="A knowledge index of learnings from all previous iterations "
        prompt+="is available at .ralph/knowledge-index.md. Consult it if you "
        prompt+="need project history beyond what's in the handoff above."$'\n\n'
    fi

    # === SKILLS (if any) ===
    if [[ -n "$skills_content" ]]; then
        prompt+="## Skills & Conventions"$'\n'
        prompt+="$skills_content"$'\n\n'
    fi

    # === OUTPUT INSTRUCTIONS ===
    prompt+="$(cat .ralph/templates/coding-prompt-footer.md 2>/dev/null || echo "$DEFAULT_OUTPUT_INSTRUCTIONS")"

    echo "$prompt"
}
```

Key difference: in `handoff-only` mode, the previous handoff narrative *is* the context section. No compacted context, no L1/L2 summaries, no token budgeting. Just the handoff.

In `handoff-plus-index` mode, the handoff still leads, but there's also a pointer to the knowledge index file on disk (not injected — just referenced).

---

## Change 3: Knowledge indexer (refactored compaction)

### What changes

The existing `compaction.sh` extracts L1/L2/L3 from handoffs and the `run_compaction_cycle()` in `ralph.sh` sends them to a memory agent that produces `compacted-latest.json`.

In v2, `handoff-plus-index` mode replaces this with a "librarian" pass that maintains a flat markdown file instead of a JSON context blob.

### New file: `.ralph/knowledge-index.json` (for dashboard)

A structured array matching the prototype's table view:

```json
[
  { "iteration": 1, "task": "TASK-001", "summary": "Project scaffold created", "tags": ["setup", "config", "schema"] },
  { "iteration": 3, "task": "TASK-003", "summary": "Git ops — checkpoint/rollback pattern", "tags": ["git", "rollback", "clean"] }
]
```

The dashboard reads this file directly to render the Knowledge Index table.

### New file: `.ralph/knowledge-index.md` (for the coding LLM)

A categorized markdown file the coding agent can scan with built-in file tools:

```markdown
# Knowledge Index
Last updated: iteration 15 (2026-02-06T14:30:00Z)

## Constraints
- git clean -fd removes .gitignore-matched files [iter 3]
- jq array slicing uses `.[0:3]` not `.[0..2]` [iter 5]

## Architectural Decisions
- Using rev-parse HEAD for checkpoints, not tags [iter 3]
- Skills loaded via --append-system-prompt-file [iter 6]

## Patterns
- All lib/ modules export functions prefixed with module name [iter 2]

## Gotchas
- Empty jq output on missing key — always use `// "default"` [iter 5]

## Unresolved
- Rate limiting detection: no clean signal from CLI [iter 10]
```

The indexer writes both files from the same pass. The JSON is iteration-centric (good for the dashboard table). The markdown is topic-centric (good for the LLM to scan by category).

### Modified: `.ralph/lib/compaction.sh` → add `run_knowledge_indexer()`

Keep all existing functions (they still work for `handoff-plus-index` mode's underlying mechanics). Add:

```bash
# run_knowledge_indexer — Reads recent handoffs, updates knowledge-index.md
# This replaces run_compaction_cycle when in handoff-plus-index mode.
run_knowledge_indexer() {
    local task_json="${1:-}"
    log "info" "--- Knowledge indexer start ---"

    local compaction_input
    compaction_input="$(build_compaction_input "${RALPH_DIR}/handoffs" "$STATE_FILE")"

    if [[ -z "$compaction_input" ]]; then
        log "info" "No new handoffs to index, skipping"
        return 0
    fi

    local indexer_prompt
    indexer_prompt="$(build_indexer_prompt "$compaction_input" "$task_json")"

    # The indexer uses the same memory MCP config but a different prompt
    local raw_response
    if ! raw_response="$(run_memory_iteration "$indexer_prompt")"; then
        log "error" "Knowledge indexer failed"
        return 1
    fi

    # The indexer writes directly to knowledge-index.md via its tools
    # (it has filesystem access through Claude Code's built-in tools)
    # We just need to update the compaction state counters
    update_compaction_state "$STATE_FILE"

    log "info" "--- Knowledge indexer end ---"
}

build_indexer_prompt() {
    local compaction_input="$1"
    local task_json="${2:-}"

    cat <<PROMPT
Read the handoff data below from recent iterations.

Produce two outputs:

1. Update .ralph/knowledge-index.md with categorized entries:
   - Constraints discovered
   - Architectural decisions made
   - Coding patterns established
   - Gotchas encountered
   - Unresolved issues
   Keep entries to one line each with iteration number in brackets.
   Remove entries that are no longer relevant.

2. Update .ralph/knowledge-index.json — a JSON array where each
   iteration gets one entry with fields: iteration, task, summary, tags.
   Append new entries for iterations not already present.

Catalog, don't summarize — keep entries scannable.

## Recent Handoff Data
${compaction_input}
PROMPT
}
```

### What happens to compacted-latest.json?

In `handoff-only` mode: never created, never used. The `context/` directory can be empty.

In `handoff-plus-index` mode: `compacted-latest.json` is no longer created. The knowledge indexer writes `knowledge-index.md` and `knowledge-index.json` instead. The old compaction history files stay on disk (read-only, no harm).

The existing `format_compacted_context()` function in `context.sh` continues to work if someone switches back — the files are still there.

---

## Change 4: Dashboard + control plane

### New files

```
.ralph/
├── telemetry/
│   └── events.jsonl             # NEW: append-only event stream
├── control/
│   └── commands.json            # NEW: dashboard → orchestrator commands
├── lib/
│   └── telemetry.sh             # NEW: event logging functions
└── dashboard.html               # NEW: single-file dashboard
```

### New module: `.ralph/lib/telemetry.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

TELEMETRY_FILE="${RALPH_DIR:-.ralph}/telemetry/events.jsonl"
CONTROL_FILE="${RALPH_DIR:-.ralph}/control/commands.json"

emit_event() {
    local event="$1"
    shift
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local json
    json=$(jq -n --arg ts "$ts" --arg event "$event" \
        '{ts: $ts, event: $event}')
    # Merge any additional key=value pairs
    while [[ $# -gt 0 ]]; do
        local key="${1%%=*}"
        local val="${1#*=}"
        json=$(echo "$json" | jq --arg k "$key" --arg v "$val" \
            '. + {($k): ($v | try tonumber // .)}')
        shift
    done
    mkdir -p "$(dirname "$TELEMETRY_FILE")"
    echo "$json" >> "$TELEMETRY_FILE"
}

# Read control commands, return current settings
read_control_commands() {
    if [[ ! -f "$CONTROL_FILE" ]]; then
        echo '{}'
        return
    fi
    cat "$CONTROL_FILE"
}

# Check if pause is requested
is_paused() {
    local cmd
    cmd="$(read_control_commands)"
    [[ "$(echo "$cmd" | jq -r '.pause // false')" == "true" ]]
}

# Clear a one-shot command (like inject_note)
clear_control_field() {
    local field="$1"
    if [[ -f "$CONTROL_FILE" ]]; then
        local tmp
        tmp="$(mktemp)"
        jq --arg f "$field" '.[$f] = null' "$CONTROL_FILE" > "$tmp"
        mv "$tmp" "$CONTROL_FILE"
    fi
}
```

### Modifications to `ralph.sh` main loop

Add at the top of each iteration:

```bash
# Emit iteration start event
emit_event "iteration_start" \
    "iteration=$current_iteration" \
    "task_id=$task_id" \
    "mode=$MODE"

# Check dashboard control commands
while is_paused; do
    log "info" "Paused by dashboard. Waiting..."
    sleep 5
done

# Check for mode override from dashboard
local ctrl_mode
ctrl_mode="$(read_control_commands | jq -r '.mode // empty')"
if [[ -n "$ctrl_mode" && "$ctrl_mode" != "$MODE" ]]; then
    log "info" "Mode changed via dashboard: $MODE → $ctrl_mode"
    MODE="$ctrl_mode"
fi

# Check for injected human note
local inject_note
inject_note="$(read_control_commands | jq -r '.inject_note // empty')"
if [[ -n "$inject_note" ]]; then
    log "info" "Human note injected: $inject_note"
    # Append to failure_context (reusing existing injection mechanism)
    failure_context+=$'\n\n'"## Note from operator"$'\n'"$inject_note"
    clear_control_field "inject_note"
fi
```

Add after coding cycle completes:

```bash
emit_event "coding_complete" \
    "iteration=$current_iteration" \
    "duration_s=$((SECONDS - iter_start))" \
    "turns=$(echo "$metadata" | jq -r '.num_turns')"
```

Add after validation:

```bash
emit_event "validation_result" \
    "iteration=$current_iteration" \
    "passed=$([[ $? -eq 0 ]] && echo true || echo false)"
```

### Control commands format: `.ralph/control/commands.json`

```json
{
  "pause": false,
  "mode": "handoff-only",
  "skip_tasks": [],
  "inject_note": null,
  "settings": {
    "validation_strategy": "strict",
    "knowledge_index_interval": 5,
    "max_turns": 20,
    "min_delay_seconds": 30
  }
}
```

### Dashboard: `.ralph/dashboard.html`

Single HTML file, Tailwind CDN, polls `events.jsonl`, `state.json`, `commands.json`, `handoffs/*.json`, and `knowledge-index.json` every 3 seconds. Writes to `commands.json` for control actions.

A React prototype already exists (`ralph-deluxe-v2.jsx`) with mock data covering the read-only views. The production dashboard can be ported from this prototype.

**Already implemented in prototype:**
- Handoff timeline with freeform narrative as primary view
- Knowledge index table (iteration, task, summary, tags) — reads from `knowledge-index.json`
- Mode toggle (handoff-only ↔ handoff + knowledge index)
- Metrics strip (iteration, tasks done, validations, rollbacks, etc.)
- Task plan panel with status badges
- Git timeline visualization
- Architecture diagrams for both modes

**Follow-up (not in prototype yet):**
- Pause/resume toggle → writes `commands.json` `pause` field
- Inject note text area → writes `commands.json` `inject_note` field
- Skip task buttons → writes `commands.json` `skip_tasks` array
- Settings panel (validation strategy, compaction interval, max turns, delay)

---

## Implementation sequence

These are changes to the existing codebase, sized for manageable PRs.

### PR 1: Handoff narrative fields
**Files changed:** `handoff-schema.json`, `coding-prompt.md`, `context.sh`
**Files added:** none
**Tests:** Update `tests/context.bats`, add test for `get_prev_handoff_for_mode()`
- Add `summary` (one-line) and `freeform` (narrative) to schema (both required)
- Update coding prompt template with the "write a handoff" framing
- Add `get_prev_handoff_for_mode()` to context.sh
- Update dry-run mock response in cli-ops.sh to include summary + freeform
- Update test fixtures: `sample-handoff.json`, `sample-handoff-002.json`, `mock-claude-response.json`

### PR 2: Mode selection
**Files changed:** `ralph.sh`, `ralph.conf`, `context.sh`, `state.json`
**Files added:** none
**Tests:** Update `tests/integration.bats` for mode flag
- Add `--mode` flag to argument parsing
- Add `RALPH_MODE` to ralph.conf
- Add `mode` field to state.json
- Wire mode into prompt assembly (use `build_coding_prompt_v2()`)
- In handoff-only mode, skip compaction trigger check entirely
- Existing compaction code stays — it just doesn't run in handoff-only mode

### PR 3: Knowledge indexer
**Files changed:** `compaction.sh`, `ralph.sh`
**Files added:** `templates/indexer-prompt.md`, `knowledge-index.json` (empty init), `knowledge-index.md` (empty init)
**Tests:** Update `tests/compaction.bats`
- Add `run_knowledge_indexer()` and `build_indexer_prompt()` to compaction.sh
- Indexer writes both `knowledge-index.json` (dashboard table) and `knowledge-index.md` (LLM categories)
- Add `run_knowledge_indexer` call in ralph.sh (handoff-plus-index mode only)
- Existing L1/L2/L3 extraction functions stay (used internally by indexer)
- Old compaction path (`run_compaction_cycle`) stays but is only used if mode is explicitly set to "legacy" (backward compat)

### PR 4: Telemetry module
**Files changed:** `ralph.sh`
**Files added:** `lib/telemetry.sh`, `telemetry/` dir, `control/commands.json`
**Tests:** Add `tests/telemetry.bats`
- Add emit_event(), is_paused(), read_control_commands()
- Wire events into ralph.sh main loop
- Add pause/resume check at top of each iteration
- Add inject_note check
- Initialize control/commands.json with defaults

### PR 5: Dashboard (read-only views)
**Files added:** `dashboard.html`
**Reference:** `ralph-deluxe-v2.jsx` prototype
**Tests:** Manual testing
- Port the existing React prototype to single HTML file (Tailwind CDN)
- Polls events.jsonl, state.json, handoffs/*.json, knowledge-index.json
- Handoff narrative timeline, mode toggle, metrics strip, task plan, git timeline
- Knowledge index table view (reads knowledge-index.json)
- Note: control plane widgets (pause, inject note, skip task) deferred to PR 6

### PR 6: Control plane
**Files changed:** `dashboard.html`, `ralph.sh`
**Tests:** Manual testing
- Add pause/resume toggle, inject note textarea, skip task buttons to dashboard
- Dashboard writes to control/commands.json
- Wire orchestrator to read commands.json each iteration

### PR 7: Documentation and cleanup
**Files changed:** `README.md`, `CLAUDE.md`, `Ralph_Deluxe_Plan.md`
- Update README with mode documentation
- Add dashboard usage instructions
- Update feature list (handoff-first framing)
- Archive v1 plan, document v2 rationale

---

## What stays exactly as-is

| Module | Status | Reason |
|--------|--------|--------|
| `git-ops.sh` | Unchanged | Checkpoint/rollback works, no mode dependency |
| `plan-ops.sh` | Unchanged | Task reading/mutation is mode-independent |
| `validation.sh` | Unchanged | Validation gates don't care about memory strategy |
| `skills/*.md` | Unchanged | Skill injection works the same in both modes |
| `mcp-coding.json` | Unchanged | Coding iterations always use built-in tools only |
| `mcp-memory.json` | Unchanged | Used by knowledge indexer in handoff-plus-index mode |
| `first-iteration.md` | Unchanged | Bootstrap prompt is mode-independent |
| `plan.json` format | Unchanged | Task schema is mode-independent |
| Test fixtures | Updated | Add summary + freeform to existing fixture JSONs |

## What the v2 diff looks like

Estimated total changes:
- **~150 lines added** (telemetry.sh, indexer functions, mode wiring)
- **~30 lines modified** (context.sh prompt assembly, ralph.sh mode checks)
- **~0 lines deleted** (backward compatible — old compaction stays)
- **1 new lib module** (telemetry.sh)
- **1 new HTML file** (dashboard.html — the big one, probably 300-500 lines)
- **Schema change**: 1 field added to handoff-schema.json

The existing codebase is ~90% preserved. The core insight — the handoff narrative — is literally one JSON field and a rewritten prompt footer.

---

## Tracking implementation progress

After completing work on each PR, update `v2-implementation-status.md` at the project root:

1. Change the PR's heading status (e.g., `NOT STARTED` → `IN PROGRESS` → `IMPLEMENTED`)
2. Mark each line item in the PR's table as `Done` or `Partial` with notes
3. Update the **Summary** table at the bottom
4. Update the `Last verified` date at the top of the file

This keeps a single source of truth for what has shipped vs. what remains. The status file lives alongside this plan so reviewers can cross-reference the two.
