# Ralph Deluxe — Progress Log Feature: Revision Plan

**Author:** Auto-generated from analysis of `v2-implementation-status.md` and `.ralph/progress-log.md`
**Date:** 2026-02-07
**Scope:** Add an auto-generated progress log to the Ralph Deluxe orchestrator
**Prerequisite:** All v2 PRs (1-7) implemented

---

## Motivation

The Ralph Deluxe system tracks progress across multiple distributed artifacts (plan.json, state.json, events.jsonl, handoffs, validation logs, git commits). This gives excellent machine-readable and real-time tracking, but lacks a single human-readable document that captures the full story of an orchestrator run: what was done, why decisions were made, what constraints were discovered, and what tests were added.

The `.ralph/progress-log.md` file created during v2 development proved valuable as an implementation journal — recording design decisions, constraints, and file-level changes that would otherwise be scattered or lost. This feature brings that same capability into the runtime system as an auto-generated artifact.

### Design Principles

1. **Auto-generated from handoffs** — no manual maintenance; the orchestrator writes it
2. **Dual format** — `.md` for human/LLM consumption, `.json` for dashboard rendering
3. **Per-task organization** — entries keyed by task ID, not iteration number
4. **Additive, not duplicative** — captures the *why* (decisions, constraints, deviations) that existing artifacts don't surface in one place
5. **Follows existing patterns** — mirrors the knowledge-index dual-file approach

---

## Architecture

### Data Flow

```
handoff-NNN.json (after validation pass)
    │
    ├─► append_progress_entry()     ← new function in progress-log.sh
    │       │
    │       ├─► .ralph/progress-log.json   (machine-readable, dashboard)
    │       └─► .ralph/progress-log.md     (human/LLM-readable)
    │
    └─► Dashboard ProgressLog panel  ← new panel in dashboard.html
            │
            └─► polls progress-log.json
```

### Integration Point in ralph.sh

After a successful validation pass, immediately after `commit_iteration` and `set_task_status ... "done"`, and before `apply_amendments`:

```bash
# Step 6a (existing): Commit successful iteration
commit_iteration "$current_iteration" "$task_id" "passed validation"
set_task_status "$PLAN_FILE" "$task_id" "done"

# Step 6b (NEW): Append progress log entry
if declare -f append_progress_entry >/dev/null 2>&1; then
    append_progress_entry "$handoff_file" "$current_iteration" "$task_id" || {
        log "warn" "Progress log update failed, continuing"
    }
fi

# Step 7 (existing): Apply plan amendments
```

This placement ensures:
- Only successful iterations are logged (not failures/rollbacks)
- The entry is written *after* the git commit, so it includes the commit hash
- Non-fatal: guarded with `declare -f` and `|| { log ... }` pattern (same as telemetry)

---

## PR 1: Progress Log Library Module

**Goal:** Create `.ralph/lib/progress-log.sh` with functions to extract progress entries from handoffs and write them to both `.md` and `.json` formats.

### New File: `.ralph/lib/progress-log.sh`

**Functions:**

#### `format_progress_entry_md()`
- **Args:** `$1` = handoff file path, `$2` = iteration number, `$3` = task_id
- **Reads:** handoff JSON fields — `task_completed`, `files_touched`, `tests_added`, `architectural_notes`, `constraints_discovered`, `deviations`, `bugs_encountered`, `summary`
- **Returns (stdout):** A markdown block formatted as:

```markdown
### TASK-003: Git operations module (Iteration 5)

**Summary:** Implemented checkpoint/rollback/commit cycle with cleanup

**Files changed (4 files):**

| File | Action |
|------|--------|
| `.ralph/lib/git-ops.sh` | created |
| `tests/git-ops.bats` | created |
| `.ralph/ralph.sh` | modified |
| `.ralph/config/ralph.conf` | modified |

**Tests added:**
- `tests/git-ops.bats`: checkpoint creates tag, rollback restores state, ...

**Design decisions:**
- Used lightweight tags instead of annotated for checkpoints
- Rollback cleans untracked files with git clean -fd

**Constraints discovered:**
- Git clean requires -fd flag for directories (impact: must handle nested new dirs)

**Deviations:**
- Planned: use git stash; Actual: used tag-based checkpoints; Reason: cleaner rollback semantics

---
```

- **Behavior:** Omits empty sections (e.g., no "Deviations" header if array is empty). Uses jq to extract fields. Counts files via `files_touched | length`.

#### `format_progress_entry_json()`
- **Args:** `$1` = handoff file path, `$2` = iteration number, `$3` = task_id
- **Returns (stdout):** A JSON object:

```json
{
  "task_id": "TASK-003",
  "iteration": 5,
  "timestamp": "2026-02-07T10:30:00Z",
  "summary": "Implemented checkpoint/rollback/commit cycle with cleanup",
  "title": "Git operations module",
  "files_changed": [
    {"path": ".ralph/lib/git-ops.sh", "action": "created"}
  ],
  "tests_added": [
    {"file": "tests/git-ops.bats", "test_names": ["checkpoint creates tag", "rollback restores state"]}
  ],
  "design_decisions": ["Used lightweight tags instead of annotated for checkpoints"],
  "constraints": [
    {"constraint": "Git clean requires -fd", "impact": "must handle nested new dirs"}
  ],
  "deviations": [
    {"planned": "use git stash", "actual": "used tag-based checkpoints", "reason": "cleaner rollback semantics"}
  ],
  "bugs": [
    {"description": "some bug", "resolution": "fixed it", "resolved": true}
  ],
  "fully_complete": true
}
```

- **Behavior:** Extracts from handoff JSON via jq. The `title` field is read from `plan.json` via `get_task_by_id()` if available, otherwise falls back to the task_id.

#### `append_progress_entry()`
- **Args:** `$1` = handoff file path, `$2` = iteration number, `$3` = task_id
- **Globals:** `RALPH_DIR`, `PLAN_FILE`
- **Behavior:**
  1. Calls `format_progress_entry_md()` and appends to `.ralph/progress-log.md`
  2. Calls `format_progress_entry_json()` and appends to `.ralph/progress-log.json`'s entries array
  3. Updates the `.ralph/progress-log.json` summary section (task counts derived from plan.json)
  4. Uses atomic write pattern (write to tmp, then mv) for the JSON file
  5. Creates files with headers if they don't exist yet

#### `init_progress_log()`
- **Args:** none
- **Globals:** `RALPH_DIR`
- **Behavior:** Creates initial `.ralph/progress-log.md` (with header) and `.ralph/progress-log.json` (with empty structure) if they don't exist

### Progress Log JSON Schema

```json
{
  "generated_at": "2026-02-07T10:30:00Z",
  "plan_summary": {
    "total_tasks": 12,
    "completed": 5,
    "pending": 6,
    "failed": 1,
    "skipped": 0
  },
  "entries": [
    { ... progress entry JSON objects ... }
  ]
}
```

### Progress Log Markdown Format

```markdown
# Ralph Deluxe — Progress Log

**Plan:** ralph-deluxe | **Generated:** auto-updated by orchestrator

| Task | Status | Summary |
|------|--------|---------|
| TASK-001 | Done | Created directory structure |
| TASK-002 | Done | Core orchestrator loop |
| TASK-003 | Pending | — |
| ... | ... | ... |

---

### TASK-001: Create directory structure (Iteration 1)
... entry ...

---

### TASK-002: Core orchestrator loop (Iteration 3)
... entry ...
```

The top-level summary table is auto-regenerated on each append (reading plan.json for current status). This gives the quick-scan benefit of the status checklist without manual maintenance.

### Acceptance Criteria

- [ ] `format_progress_entry_md` produces valid markdown from a sample handoff
- [ ] `format_progress_entry_md` omits empty sections (no "Deviations:" header when array is empty)
- [ ] `format_progress_entry_json` produces valid JSON from a sample handoff
- [ ] `append_progress_entry` creates files if they don't exist
- [ ] `append_progress_entry` appends to existing files without overwriting
- [ ] `init_progress_log` is idempotent (running twice doesn't duplicate headers)
- [ ] JSON output validates with `jq .`
- [ ] Summary table in markdown reflects current plan.json status

---

## PR 2: Orchestrator Integration

**Goal:** Wire `append_progress_entry()` into the ralph.sh main loop and the dry-run path.

### Changes to `.ralph/ralph.sh`

1. **Real mode (after validation pass, ~line 591):** Add `append_progress_entry` call between `set_task_status ... "done"` and `apply_amendments`, guarded with `declare -f`.

2. **Dry-run mode (~line 532):** Add `append_progress_entry` call after `set_task_status ... "done"`, guarded with `declare -f`.

3. **Initialization (~line 453):** After `source_libs` and `init_control_file`, add:
   ```bash
   if declare -f init_progress_log >/dev/null 2>&1; then
       init_progress_log
   fi
   ```

### Guard Pattern

All calls follow the existing telemetry guard pattern:
```bash
if declare -f append_progress_entry >/dev/null 2>&1; then
    append_progress_entry "$handoff_file" "$current_iteration" "$task_id" || {
        log "warn" "Progress log update failed, continuing"
    }
fi
```

This ensures:
- The orchestrator works if progress-log.sh fails to load
- A progress log failure never blocks the main loop
- Consistent with how `emit_event` is guarded throughout ralph.sh

### Acceptance Criteria

- [ ] Progress log entry written after each successful iteration in real mode
- [ ] Progress log entry written after each dry-run iteration
- [ ] Progress log files initialized at orchestrator startup
- [ ] Failure in `append_progress_entry` does not halt the orchestrator
- [ ] Orchestrator works correctly if progress-log.sh is not sourced (graceful degradation)
- [ ] Both `.ralph/progress-log.md` and `.ralph/progress-log.json` are updated

---

## PR 3: Dashboard Panel

**Goal:** Add a ProgressLog panel to the dashboard that renders entries from `.ralph/progress-log.json`.

### Changes to `.ralph/dashboard.html`

#### New Data Polling

Add to the poll cycle (alongside state.json, plan.json, etc.):
```javascript
// In fetchData():
fetch(".ralph/progress-log.json").then(r => r.ok ? r.json() : null)
    .then(data => { if (data) state.progressLog = data; })
    .catch(() => {});
```

#### New State Field

```javascript
// In global state:
progressLog: { plan_summary: {}, entries: [] }
```

#### New Component: `ProgressLog()`

A panel with two views, toggled by a tab bar:

**Summary View (default):**
- Renders `plan_summary` as a compact status bar (e.g., "5/12 tasks done, 1 failed")
- Shows a table of all tasks with status badges (like TaskPlan, but with summary text from progress entries)

**Detail View:**
- List of expandable progress entries (one per task)
- Each entry shows: summary line, files changed table, tests added, design decisions, constraints, deviations
- Entries are collapsible (click to expand/collapse)
- Color-coded left border: emerald for complete, amber for partial, red for bugs unresolved

#### Panel Placement

Between the existing HandoffViewer and KnowledgeIndex panels. The ProgressLog replaces the need to manually click through individual handoffs to understand the project history.

#### Styling

Follows existing dashboard patterns:
- `bg-zinc-900 rounded-lg border border-zinc-800` container
- `text-zinc-400` labels, `text-zinc-200` values
- Tailwind CDN classes only (no custom CSS beyond existing styles)
- `h()` helper for DOM construction (same as all other components)

### Acceptance Criteria

- [ ] Dashboard polls `.ralph/progress-log.json` every 3 seconds
- [ ] Summary view shows task completion counts
- [ ] Detail view renders all progress entry fields
- [ ] Empty state handled gracefully (shows "No progress entries yet")
- [ ] Entries are expandable/collapsible
- [ ] Panel renders correctly when `progress-log.json` doesn't exist yet
- [ ] Follows existing dashboard component patterns (h() helper, StatusBadge reuse)

---

## PR 4: Test Suite

**Goal:** Comprehensive bats tests for the progress log module.

### New File: `tests/progress-log.bats`

#### Setup/Teardown

```bash
setup() {
    TEST_DIR="$(mktemp -d)"
    export RALPH_DIR="$TEST_DIR/.ralph"
    export PLAN_FILE="$TEST_DIR/plan.json"
    mkdir -p "$RALPH_DIR"/{handoffs,lib,logs}
    # Create sample plan.json
    # Create sample handoff JSON
    # Source progress-log.sh (and stubs for dependencies)
}

teardown() {
    rm -rf "$TEST_DIR"
}
```

#### Test Cases (~20 tests)

**`format_progress_entry_md` tests:**
1. Produces markdown with all sections from a full handoff
2. Omits empty "Deviations" section when deviations array is empty
3. Omits empty "Constraints" section when constraints array is empty
4. Omits empty "Tests added" section when tests_added array is empty
5. Omits empty "Bugs" section when bugs_encountered array is empty
6. File count in header matches files_touched length
7. Handles handoff with no optional fields (empty arrays everywhere)

**`format_progress_entry_json` tests:**
8. Output is valid JSON
9. Contains all required fields (task_id, iteration, summary, files_changed, etc.)
10. Extracts title from plan.json when get_task_by_id is available
11. Falls back to task_id when plan.json lookup fails
12. Handles handoff with empty arrays gracefully

**`append_progress_entry` tests:**
13. Creates progress-log.md and progress-log.json when they don't exist
14. Appends a second entry without overwriting the first
15. Updates plan_summary counts in JSON from plan.json
16. JSON output validates with `jq .` after multiple appends
17. Markdown contains summary table with correct task count

**`init_progress_log` tests:**
18. Creates both files with correct initial structure
19. Is idempotent — running twice doesn't duplicate content
20. JSON file has empty entries array and zero-count summary

### Changes to `tests/integration.bats`

Add 2-3 integration tests:
1. Progress log files created after dry-run completes
2. Progress log entry appears after successful iteration
3. Progress log not written after validation failure (rollback)

### Acceptance Criteria

- [ ] All bats tests pass
- [ ] Tests run in temp directories (no project pollution)
- [ ] Each test is independent (setup/teardown isolation)
- [ ] Edge cases covered: empty handoffs, missing files, repeated calls
- [ ] Tests run in under 10 seconds

---

## PR 5: Documentation Update

**Goal:** Update README.md and CLAUDE.md to document the progress log feature.

### Changes to `README.md`

- Add "Progress Log" to the features list
- Add `.ralph/progress-log.md` and `.ralph/progress-log.json` to the directory structure
- Add a "Progress Log" subsection explaining auto-generation from handoffs
- Mention the dashboard ProgressLog panel

### Changes to `CLAUDE.md`

- Add `progress-log.md` and `progress-log.json` to the directory structure
- Add `.ralph/lib/progress-log.sh` to the library modules list
- Add `tests/progress-log.bats` to the testing section

### Changes to `.ralph/dashboard.html` File Comment

Update the component list comment at the top of the script section.

### Acceptance Criteria

- [ ] README documents the progress log feature
- [ ] CLAUDE.md directory structure includes new files
- [ ] Documentation is consistent with implementation

---

## Implementation Order and Dependencies

```
PR 1: Progress Log Library Module
  └──► PR 2: Orchestrator Integration (depends on PR 1)
  └──► PR 4: Test Suite (depends on PR 1, can start in parallel with PR 2)

PR 3: Dashboard Panel (independent of PR 1/2, only needs JSON schema agreement)

PR 5: Documentation (depends on all above)
```

**Recommended execution order:** PR 1 → PR 2 + PR 4 (parallel) → PR 3 → PR 5

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Progress log write blocks main loop | Low | High | `declare -f` guard + `\|\| { log warn }` — same pattern as telemetry |
| JSON file corruption from concurrent write | Low | Medium | Atomic write pattern (tmp + mv) — same as state.json, commands.json |
| Large progress-log.md slows dashboard | Low | Low | Dashboard reads JSON file, not markdown; JSON entries are compact |
| Markdown format doesn't render well | Low | Low | Uses standard GFM tables and headers; tested against existing patterns |

---

## Files Changed (Summary)

| File | PR | Change |
|------|-----|--------|
| `.ralph/lib/progress-log.sh` | PR 1 | **New.** ~120 lines: format_progress_entry_md, format_progress_entry_json, append_progress_entry, init_progress_log |
| `.ralph/ralph.sh` | PR 2 | ~10 lines: append_progress_entry call in real + dry-run paths, init_progress_log at startup |
| `.ralph/dashboard.html` | PR 3 | ~100 lines: ProgressLog component, data polling, state field |
| `tests/progress-log.bats` | PR 4 | **New.** ~200 lines: 20 tests |
| `tests/integration.bats` | PR 4 | ~30 lines: 2-3 new integration tests |
| `README.md` | PR 5 | ~20 lines: feature docs, directory structure |
| `CLAUDE.md` | PR 5 | ~5 lines: directory structure, module list |
