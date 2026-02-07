# Ralph-Deluxe v2 — Progress Log

**Purpose:** Consolidated record of all PR implementations, handoffs, and design decisions.
This is a working reference file — not a handoff prompt. For current status, see `v2-implementation-status.md`.

---

## PR 1: Handoff Narrative Fields

**Files changed (6 files, +128/-18):**

| File | Change |
|------|--------|
| `.ralph/config/handoff-schema.json` | Added `summary` (string, required) and `freeform` (string, required) as top-level properties with descriptions; added both to the `required` array |
| `.ralph/templates/coding-prompt.md` | Replaced "Output Requirements" section with "When You're Done" section; frames output as handoff briefing; names `freeform` as most important field |
| `.ralph/lib/context.sh` | Added `get_prev_handoff_for_mode()` (38 lines) — handoff-only returns freeform narrative; handoff-plus-index returns freeform + structured L2 context |
| `.ralph/lib/cli-ops.sh` | Updated dry-run mock response to include `summary` and `freeform` fields |
| Test fixtures (4 files) | Added `summary` and `freeform` to `sample-handoff.json`, `sample-handoff-002.json`, `sample-handoff-partial.json`, and `mock-claude-response.json` |
| `tests/context.bats` | Added 5 new tests for `get_prev_handoff_for_mode()` |

**Test results:** All 52 tests pass (27 context + 25 cli-ops).

**Design decisions:**
- `get_prev_handoff_summary()` preserved for backward compatibility
- `get_prev_handoff_for_mode()` is the new mode-aware function used by PR 2's prompt assembly

---

## PR 2: Mode Selection (--mode flag)

**Files changed (6 files):**

| File | Change |
|------|--------|
| `.ralph/ralph.sh` | Added `--mode` flag to CLI parsing; mode resolution priority (CLI > config > default); mode persistence to `state.json`; compaction gating behind `handoff-plus-index` mode; `build_coding_prompt_v2` wiring in `run_coding_cycle` |
| `.ralph/lib/context.sh` | Added `build_coding_prompt_v2()` — mode-aware prompt assembly; handoff-only: narrative IS the context; handoff-plus-index: narrative leads + pointer to `knowledge-index.md` + structured L2 |
| `.ralph/config/ralph.conf` | Added `RALPH_MODE="handoff-only"` setting |
| `.ralph/state.json` | Added `"mode": "handoff-only"` field |
| `tests/context.bats` | 9 new tests for `build_coding_prompt_v2()` (both modes, knowledge index pointer, failure context, skills, first-iteration, section priority) |
| `tests/integration.bats` | 6 new tests (default mode, explicit mode, log output, config fallback, CLI override, compaction gating); fixed git signing for test isolation |

**Test results:** 36 context tests (27 original + 9 new), 16 integration tests (10 original + 6 new) — all pass.

**Acceptance criteria met:**
- `ralph.sh --mode handoff-plus-index` sets MODE correctly
- Defaults to `handoff-only` when no `--mode` flag given
- `RALPH_MODE` in `ralph.conf` respected as fallback
- In `handoff-only` mode, `check_compaction_trigger` is never called
- `build_coding_prompt_v2()` uses `get_prev_handoff_for_mode()` for context injection
- `build_coding_prompt_v2()` includes knowledge index pointer only in `handoff-plus-index` mode

---

## PR 3: Knowledge Indexer (Compaction Replacement)

**Files changed (6 files, +349/-29):**

| File | Change |
|------|--------|
| `.ralph/templates/knowledge-index-prompt.md` | **New.** Prompt template for categorized `knowledge-index.md` (for LLM) and iteration-keyed `knowledge-index.json` (for dashboard) |
| `.ralph/lib/compaction.sh` | Added `build_indexer_prompt()` (lines 102-126) and `run_knowledge_indexer()` (lines 128-165) |
| `.ralph/ralph.sh` | Both dry-run (line 498) and real mode (line 516) paths call `run_knowledge_indexer()` instead of `run_compaction_cycle()` when in `handoff-plus-index` mode |
| `tests/compaction.bats` | 9 new tests (5 for `build_indexer_prompt`, 4 for `run_knowledge_indexer`); setup expanded for RALPH_DIR structure |
| `tests/integration.bats` | 2 new tests (indexer triggers in h+i mode when thresholds met; skips below thresholds) |
| `v2-implementation-status.md` | Marked PR 2 and PR 3 as IMPLEMENTED |

**Test results:** 34 compaction tests (25 original + 9 new), 36 context tests, 18 integration tests — all pass.

**Design decisions:**
- Separate function, not a modification of existing compaction
- Old compaction functions (`extract_l1/l2/l3`, `build_compaction_input`, `run_compaction_cycle`) untouched for backward compatibility
- Reuses `build_compaction_input()` for handoff data and `run_memory_iteration()` for CLI call
- `build_indexer_prompt()` includes existing `knowledge-index.md` content for incremental updates
- Template-driven: prompt lives in `.ralph/templates/knowledge-index-prompt.md`

**Constraints discovered:**
- `run_memory_iteration()` enforces `--json-schema` with `memory-output-schema.json`, so knowledge index files must be written by Claude as tool-use side effects during the iteration
- `build_compaction_input()` returns empty string (whitespace-only) when no handoffs qualify

---

## PR 4: Telemetry Module

**Files changed (4 files):**

| File | Change |
|------|--------|
| `.ralph/lib/telemetry.sh` | **New.** 160 lines: `emit_event()`, `init_control_file()`, `read_pending_commands()`, `clear_pending_commands()`, `process_control_commands()`, `wait_while_paused()`, `check_and_handle_commands()` |
| `.ralph/control/commands.json` | **New.** Initial control file with `{"pending": []}` |
| `.ralph/ralph.sh` | ~50 lines added: telemetry integration at lifecycle points (`orchestrator_start/end`, `iteration_start/end`, `validation_pass/fail`); control command check in loop; shutdown signal emits `orchestrator_end` |
| `tests/telemetry.bats` | **New.** 32 tests covering all functions and JSONL stream integrity |

**Test results:** 32 telemetry tests, 34 compaction tests, 103 module tests (context, plan-ops, validation, cli-ops), 18 integration tests — all pass.

**Design decisions:**
- **Queue-based control model**, not key-value. The revision plan described `commands.json` as `{"pause": false, "mode": "...", "inject_note": null}`. Implemented as `{"pending": [{"command": "pause"}, ...]}` — a command queue cleared after processing. Better fit because: commands are one-shot actions, ordering preserved, dashboard can enqueue multiple commands between polls without race conditions.
- **Events file location:** `.ralph/logs/events.jsonl` (not `.ralph/telemetry/events.jsonl` as plan suggested). Keeps all log artifacts in `logs/`.
- **Event schema:** Each JSONL line is `{timestamp, event, message, metadata}`. Event names: `orchestrator_start`, `orchestrator_end`, `iteration_start`, `iteration_end`, `validation_pass`, `validation_fail`, `pause`, `resume`, `note`.
- **Guard pattern:** All `emit_event` calls in `ralph.sh` wrapped in `if declare -f emit_event >/dev/null 2>&1` guards — orchestrator works even if telemetry.sh fails to load.

**Constraints discovered:**
- Default metadata quoting: `emit_event()` default metadata parameter required `"${3:-"{}"}"` — bare `{}` fails `jq --argjson` validation
- Control file format diverges from plan: queue-based `{pending: [...]}` vs. plan's flat key-value

---

## PR 5: Dashboard (Read-Only Views)

**Files changed (2 files):**

| File | Change |
|------|--------|
| `.ralph/dashboard.html` | **New.** 871-line single-file dashboard (vanilla JS + Tailwind CSS CDN) |
| `v2-implementation-status.md` | Marked PR 4 and PR 5 as IMPLEMENTED |

**Dashboard panels (ported from `ralph-deluxe-v2.jsx` prototype):**
- **StatusBadge** — colored pills for all states
- **ModeToggle** — handoff-only / handoff+index toggle (read-only, mirrors orchestrator mode)
- **MetricsStrip** — 8 metric cards computed from `events.jsonl` + handoffs + `state.json`
- **TaskPlan** — task list with status badges, current-task highlight, completion counter
- **HandoffViewer** — numbered handoff selector with summary, freeform narrative, deviations, constraints, architecture notes, files touched
- **KnowledgeIndex** — table view (iter, task, summary, tags); disabled message in handoff-only mode
- **GitTimeline** — visual dot timeline with pass/fail/running color coding
- **ArchDiagram** — ASCII architecture diagrams for both modes
- **EventLog** — live event stream (last 50 events, newest first, color-coded by type) — *added beyond prototype*

**Data polling (every 3s):** `state.json`, `plan.json`, `handoffs/*.json`, `knowledge-index.json`, `events.jsonl`

**Usage:** `cd` to project root, run `python3 -m http.server 8080`, open `http://localhost:8080/.ralph/dashboard.html`. File:// protocol detected with instructions.

**Test results:** All 187 non-git-signing tests pass.

**Design decisions:**
- DOM rendering via `h()` helper, not innerHTML templates — each component returns a DOM node
- Full rebuild `render()` on each poll cycle (implication: form inputs lose state on re-render)
- Handoff discovery by sequential probing (up to `max(current_iteration + 5, 20)`)
- ModeToggle has local view override (`state.viewMode`) that doesn't write to any file

**Constraints discovered:**
- Browser cannot write local files — fetch with PUT/POST to local path doesn't work; server-side write endpoint required for PR 6
- Handoff discovery requires probing — can't list directory contents via fetch
- Full-rebuild render means PR 6 must preserve form state across render cycles

---

## PR 6: Control Plane — NOT STARTED

**Planned work:**
1. Pause/Resume toggle → enqueues `{"command": "pause"}` / `{"command": "resume"}` to `commands.json`
2. Inject Note textarea → enqueues `{"command": "inject-note", "note": "..."}`
3. Skip Task button → enqueues `{"command": "skip-task", "task_id": "..."}` (needs new handler in `telemetry.sh`)
4. Settings panel (optional) — mode switch, validation strategy, compaction threshold
5. Tiny HTTP server (`.ralph/serve.py`, ~30 lines) for dashboard write support
6. `skip-task` command handling in `process_control_commands()` in `telemetry.sh`

**Key constraint:** Dashboard runs in browser, cannot write local files directly. Recommended approach: minimal Python HTTP server with POST endpoint for `/api/command`.

---

## PR 7: Documentation and Cleanup — NOT STARTED

**Planned work:**
- README.md update with mode documentation
- CLAUDE.md update with v2 conventions
- Dashboard usage instructions
- Archive v1 plan, document v2 rationale
