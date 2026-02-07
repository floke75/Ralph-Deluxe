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

## PR 6: Control Plane — IMPLEMENTED

**Files changed (3 files):**

| File | Change |
|------|--------|
| `.ralph/serve.py` | **New.** 155-line Python HTTP server: static file serving from project root + POST `/api/command` (enqueues to `commands.json` pending array) + POST `/api/settings` (updates `ralph.conf` with allowlisted keys). Atomic writes via write-to-temp-then-rename. CORS preflight support. Input sanitization for settings values. |
| `.ralph/lib/telemetry.sh` | Added `skip-task` case to `process_control_commands()` (~15 lines). Calls `set_task_status()` to mark task as "skipped". Emits `skip_task` event with task_id metadata. Graceful degradation: if `set_task_status` is not available (standalone testing), still emits event with `applied: false` metadata. |
| `.ralph/dashboard.html` | Added ~200 lines: `ControlPlane()` component (pause/resume toggle, inject note textarea), `SettingsPanel()` component (mode, validation strategy, compaction interval, max turns, delay), skip-task buttons on pending tasks in `TaskPlan()`, persistent `formState` object for form values across full-rebuild render cycles, `postCommand()` and `postSettings()` API helpers, command status flash notifications. Updated file:// warning to recommend `serve.py`. |
| `tests/telemetry.bats` | 4 new tests for skip-task: with set_task_status available, event emission, without set_task_status, pending cleared after processing. |

**Test results:** 36 telemetry tests (32 original + 4 new), all 191 non-git-signing tests pass.

**Design decisions:**
- **serve.py architecture:** Single-file HTTP server extending `SimpleHTTPRequestHandler`. Serves all static files (dashboard, state.json, handoffs, etc.) and adds two POST endpoints. Uses `os.replace()` for atomic writes, preventing race conditions with the orchestrator reading `commands.json` simultaneously.
- **Settings allowlist:** Only `RALPH_MODE`, `RALPH_VALIDATION_STRATEGY`, `RALPH_COMPACTION_INTERVAL`, `RALPH_DEFAULT_MAX_TURNS`, `RALPH_MIN_DELAY_SECONDS` can be updated via the dashboard. Values are sanitized to alphanumeric + hyphens + underscores only.
- **Form state persistence:** The `formState` object lives outside the `render()` function, persisting textarea content and panel open/close state across the full-rebuild render cycle (constraint from PR 5).
- **Skip task flow:** Dashboard POSTs `{"command": "skip-task", "task_id": "TASK-NNN"}` → serve.py enqueues to `commands.json` → orchestrator's `process_control_commands()` reads it → calls `set_task_status(plan_file, task_id, "skipped")` → `is_plan_complete()` treats "skipped" as complete (already handled by plan-ops.sh).
- **Command status flash:** After any API call, a temporary status banner shows success/failure for 5 seconds. Cleared on next render cycle by timestamp check.

**Constraints discovered:**
- **CORS required:** Even when serving from the same origin via serve.py, some browser configurations require explicit CORS headers. Added `Access-Control-Allow-Origin: *` to all API responses and a `do_OPTIONS()` handler for preflight.
- **Settings updates are regex-based:** The serve.py settings endpoint uses regex substitution on `ralph.conf`, which means it can only update existing keys (won't add new ones). This is intentional — the conf file is the authoritative template.

---

---

## PR 7: Documentation and Cleanup — IMPLEMENTED

**Files changed (3 files):**

| File | Change |
|------|--------|
| `README.md` | Full rewrite: handoff-first framing in description and features list; new Operating Modes section documenting both modes; new Dashboard section with serve.py startup instructions, panel descriptions, and control plane actions; updated CLI Options (added `--mode`); updated Configuration table (added `RALPH_MODE`); updated Directory Structure reflecting all v2 additions (serve.py, dashboard.html, telemetry.sh, control/, knowledge-index files, events.jsonl); updated How It Works flow (12 steps including telemetry and control commands); new Handoff Schema, Knowledge Indexer, and Telemetry subsections; new v2 Design Rationale section; added Python 3 to prerequisites |
| `CLAUDE.md` | Updated Overview to handoff-first framing with two modes; added Operating Modes, Handoff Schema, Telemetry, Dashboard sections; expanded Directory Structure with all v2 files; added `// "default"` jq convention |
| `Ralph_Deluxe_Plan.md` | Added archive header documenting v2 supersession: explains the five key v2 changes, notes that L1/L2/L3 compaction is preserved for backward compatibility, and points to `ralph-deluxe-v2-revision-plan 2.md` for the v2 spec |

**Design decisions:**
- **README is the primary user-facing doc**: Full rewrite rather than incremental additions. Organized around v2 concepts (modes, dashboard, handoff narrative) as the primary framing, with legacy compaction mentioned only in the v2 rationale section
- **CLAUDE.md matches the system prompt version**: The CLAUDE.md that was already being used as the system prompt (from prior PRs) was the v2 version. This PR brings the on-disk CLAUDE.md into alignment
- **v1 plan archived in place**: Rather than moving Ralph_Deluxe_Plan.md to a subdirectory, added a prominent archive header. The file stays at the same path for existing links/references but is clearly marked as superseded

**Acceptance criteria met:**
- README.md documents both operating modes with usage examples
- README.md includes dashboard startup instructions (serve.py)
- README.md feature list uses handoff-first framing
- CLAUDE.md reflects v2 conventions (telemetry, dashboard, modes, knowledge indexer, control commands)
- Ralph_Deluxe_Plan.md has archive header pointing to v2 revision plan
- v2-implementation-status.md has PR 7 marked IMPLEMENTED with all items Done
