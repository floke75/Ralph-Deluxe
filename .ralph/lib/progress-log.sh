#!/usr/bin/env bash
set -euo pipefail

# progress-log.sh — Synthesized human + machine progress logs
#
# MODULE OVERVIEW:
#   Iteration handoff payloads are rich but ephemeral: they describe what happened in a
#   single pass through the loop, while operators and dashboards need a durable timeline.
#   This module synthesizes a persistent progress record by combining:
#     1) Hand-off level execution detail (summary/files/tests/notes/bugs), and
#     2) Plan-level task state from plan.json (status + aggregate counts).
#
#   The result is two coordinated artifacts with shared semantics:
#     - .ralph/progress-log.md   -> human/LLM-readable narrative + live task table
#     - .ralph/progress-log.json -> machine-readable feed for polling/visualization
#
#   Why synthesize instead of copying raw state?
#     - Raw handoffs are task-iteration scoped and not directly query-friendly.
#     - Plan state alone lacks per-iteration rationale and evidence.
#     - The merged log preserves both accountability (what changed, why) and status
#       observability (where each task currently stands).
#
# DEPENDENCIES:
#   Called by: ralph.sh main loop step 6b (append_progress_entry), after validation pass
#   Depends on: jq, log() from ralph.sh
#   Calls: get_task_by_id() from plan-ops.sh (for title resolution)
#   Globals read: RALPH_DIR, PLAN_FILE
#   Files written: .ralph/progress-log.md, .ralph/progress-log.json
#   Files read: plan.json (for summary table generation)
#
# DATA FLOW:
#   append_progress_entry(handoff_file, iteration, task_id)
#     → format_progress_entry_json() → appends to .ralph/progress-log.json
#     → format_progress_entry_md() → appends to .ralph/progress-log.md
#     → _regenerate_progress_md() → rebuilds md with updated summary table
#
# STRUCTURE of progress-log.md:
#   1. Header (title, plan name)
#   2. Summary table (task | status | summary) — rebuilt from plan.json each time
#   3. --- separator
#   4. Per-iteration entries (### blocks with files, tests, decisions, bugs)

# log() stub for standalone testing — ralph.sh provides the real one
if ! declare -f log >/dev/null 2>&1; then
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2" >&2; }
fi

# Create both progress log files with initial structure if they don't exist.
# Called at orchestrator startup and lazily by append_progress_entry.
# SIDE EFFECT: Creates .ralph/progress-log.md and .ralph/progress-log.json
init_progress_log() {
    local ralph_dir="${RALPH_DIR:-.ralph}"
    local md_file="${ralph_dir}/progress-log.md"
    local json_file="${ralph_dir}/progress-log.json"

    if [[ ! -f "$md_file" ]]; then
        cat > "$md_file" <<'EOF'
# Ralph Deluxe — Progress Log

**Plan:** ralph-deluxe | **Generated:** auto-updated by orchestrator

---
EOF
        log "info" "Initialized progress log: $md_file"
    fi

    if [[ ! -f "$json_file" ]]; then
        local timestamp
        timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        jq -n --arg ts "$timestamp" '{
            generated_at: $ts,
            plan_summary: {
                total_tasks: 0,
                completed: 0,
                pending: 0,
                failed: 0,
                skipped: 0
            },
            entries: []
        }' > "$json_file"
        log "info" "Initialized progress log: $json_file"
    fi
}

# Format one iteration handoff into a markdown entry body.
#
# Data sources:
#   - Handoff JSON fields: .summary, .files_touched, .tests_added,
#     .architectural_notes, .constraints_discovered, .deviations,
#     .bugs_encountered
#   - Plan/state lookup: task title is resolved from plan.json via get_task_by_id()
#     when available; otherwise task_id is used as a fallback label.
#
# Markdown generation semantics:
#   - Always emits a section header + summary line.
#   - Optional sections are emitted only when source arrays are non-empty.
#   - Section order is stable across runs to keep diffs predictable.
#   - Output is a standalone markdown fragment consumed by _regenerate_progress_md().
#
# Assumptions:
#   - Missing handoff fields are treated as empty/"No summary" (not errors).
#   - If plan lookup is unavailable/incomplete, title fallback keeps logging non-blocking.
# Args: $1 = handoff file path, $2 = iteration number, $3 = task_id
# Stdout: markdown block (consumed by _regenerate_progress_md)
format_progress_entry_md() {
    local handoff_file="$1"
    local iteration="$2"
    local task_id="$3"

    local title
    title="$(_resolve_task_title "$task_id")"

    local summary
    summary="$(jq -r '.summary // "No summary"' "$handoff_file")"

    # Header
    printf '### %s: %s (Iteration %s)\n\n' "$task_id" "$title" "$iteration"
    printf '**Summary:** %s\n' "$summary"

    # Files changed
    local files_count
    files_count="$(jq '.files_touched // [] | length' "$handoff_file")"
    if [[ "$files_count" -gt 0 ]]; then
        printf '\n**Files changed (%s files):**\n\n' "$files_count"
        printf '| File | Action |\n'
        printf '|------|--------|\n'
        jq -r '.files_touched[] | "| `\(.path)` | \(.action) |"' "$handoff_file"
    fi

    # Tests added
    local tests_count
    tests_count="$(jq '.tests_added // [] | length' "$handoff_file")"
    if [[ "$tests_count" -gt 0 ]]; then
        printf '\n**Tests added:**\n'
        jq -r '.tests_added[] | "- `\(.file)`: \(.test_names | join(", "))"' "$handoff_file"
    fi

    # Design decisions (from architectural_notes)
    local notes_count
    notes_count="$(jq '.architectural_notes // [] | length' "$handoff_file")"
    if [[ "$notes_count" -gt 0 ]]; then
        printf '\n**Design decisions:**\n'
        jq -r '.architectural_notes[] | "- \(.)"' "$handoff_file"
    fi

    # Constraints discovered
    local constraints_count
    constraints_count="$(jq '.constraints_discovered // [] | length' "$handoff_file")"
    if [[ "$constraints_count" -gt 0 ]]; then
        printf '\n**Constraints discovered:**\n'
        jq -r '.constraints_discovered[] | "- \(.constraint) (impact: \(.impact))"' "$handoff_file"
    fi

    # Deviations
    local deviations_count
    deviations_count="$(jq '.deviations // [] | length' "$handoff_file")"
    if [[ "$deviations_count" -gt 0 ]]; then
        printf '\n**Deviations:**\n'
        jq -r '.deviations[] | "- Planned: \(.planned); Actual: \(.actual); Reason: \(.reason)"' "$handoff_file"
    fi

    # Bugs encountered
    local bugs_count
    bugs_count="$(jq '.bugs_encountered // [] | length' "$handoff_file")"
    if [[ "$bugs_count" -gt 0 ]]; then
        printf '\n**Bugs encountered:**\n'
        jq -r '.bugs_encountered[] | "- \(.description) — Resolution: \(.resolution) [\(if .resolved then "resolved" else "unresolved" end)]"' "$handoff_file"
    fi

    printf '\n---\n'
}

# Format one iteration handoff into a normalized JSON entry.
#
# Data sources:
#   - Handoff JSON provides per-iteration detail fields.
#   - Plan/state lookup resolves title metadata only (task status/counts are injected
#     separately at file update time via _generate_plan_summary_json()).
#
# JSON generation semantics:
#   - Produces a compact, single-entry object suitable for insertion into .entries[].
#   - Optional array/object fields are normalized to empty arrays when absent.
#   - Adds synthesized metadata (timestamp/title/task_id/iteration).
#   - fully_complete is derived from .task_completed.fully_complete with false default.
#
# Assumptions:
#   - Handoff may be partial; absent keys should not break dashboard ingestion.
# Args: $1 = handoff file path, $2 = iteration number, $3 = task_id
# Stdout: compact JSON object
format_progress_entry_json() {
    local handoff_file="$1"
    local iteration="$2"
    local task_id="$3"

    local title
    title="$(_resolve_task_title "$task_id")"

    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    jq -c \
        --arg task_id "$task_id" \
        --argjson iteration "$iteration" \
        --arg timestamp "$timestamp" \
        --arg title "$title" \
        '{
            task_id: $task_id,
            iteration: $iteration,
            timestamp: $timestamp,
            summary: (.summary // "No summary"),
            title: $title,
            files_changed: [(.files_touched // [])[] | {path, action}],
            tests_added: [(.tests_added // [])[] | {file, test_names}],
            design_decisions: (.architectural_notes // []),
            constraints: [(.constraints_discovered // [])[] | {constraint, impact}],
            deviations: [(.deviations // [])[] | {planned, actual, reason}],
            bugs: [(.bugs_encountered // [])[] | {description, resolution, resolved}],
            fully_complete: (.task_completed.fully_complete // false)
        }' "$handoff_file"
}

# Append one synthesized progress entry to both .md and .json logs.
#
# Update timing in iteration lifecycle:
#   - Called by ralph.sh step 6b, after iteration validation succeeds.
#   - Intended to run once per accepted iteration result (not during planning).
#   - Runs before the next iteration begins so downstream polling sees latest status.
#
# Update semantics:
#   - JSON log: deduplicates by (task_id, iteration), refreshes generated_at,
#     recomputes plan_summary counts from current plan.json, then appends entry.
#   - Markdown log: fully regenerated so the summary table always reflects latest
#     task statuses, then prior entries + new entry are preserved in order.
#
# Assumptions about plan/task state:
#   - Expected task statuses include done, pending, in_progress, failed, skipped.
#   - Unknown statuses are preserved verbatim in markdown display and excluded from
#     known aggregate buckets unless matched explicitly.
#   - Missing/unfinished plan.json is tolerated: empty summaries are emitted and
#     entry append remains best-effort non-blocking.
# Args: $1 = handoff file path, $2 = iteration number, $3 = task_id
# Returns: 0 on success, 1 on failure
# CALLER: ralph.sh main loop step 6b
append_progress_entry() {
    local handoff_file="$1"
    local iteration="$2"
    local task_id="$3"

    local ralph_dir="${RALPH_DIR:-.ralph}"
    local md_file="${ralph_dir}/progress-log.md"
    local json_file="${ralph_dir}/progress-log.json"

    # Initialize files if they don't exist
    init_progress_log

    # Generate both formatted entries
    local md_entry
    md_entry="$(format_progress_entry_md "$handoff_file" "$iteration" "$task_id")"

    local json_entry
    json_entry="$(format_progress_entry_json "$handoff_file" "$iteration" "$task_id")"

    # Update JSON file (dedup by task_id+iteration, then append new entry)
    local plan_summary
    plan_summary="$(_generate_plan_summary_json)"

    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    local tmp
    tmp="$(mktemp)"
    jq --argjson entry "$json_entry" \
       --argjson summary "$plan_summary" \
       --arg ts "$timestamp" \
       '
       .generated_at = $ts |
       .plan_summary = $summary |
       .entries = [.entries[] | select(.task_id != $entry.task_id or .iteration != $entry.iteration)] + [$entry]
       ' "$json_file" > "$tmp" && mv "$tmp" "$json_file"

    # Regenerate MD file with updated summary table + new entry
    _regenerate_progress_md "$md_file" "$md_entry"

    log "info" "Appended progress log entry for $task_id (iteration $iteration)"
}

# Resolve task title from plan.json, falling back to task_id.
# Depends on get_task_by_id() from plan-ops.sh; degrades gracefully if unavailable.
# Args: $1 = task_id
# Stdout: task title string
_resolve_task_title() {
    local task_id="$1"
    local title="$task_id"

    if declare -f get_task_by_id >/dev/null 2>&1; then
        local plan_file="${PLAN_FILE:-plan.json}"
        if [[ -f "$plan_file" ]]; then
            local task_json
            task_json="$(get_task_by_id "$plan_file" "$task_id")"
            if [[ -n "$task_json" ]]; then
                local resolved
                resolved="$(echo "$task_json" | jq -r '.title // empty')"
                if [[ -n "$resolved" ]]; then
                    title="$resolved"
                fi
            fi
        fi
    fi

    printf '%s' "$title"
}

# Generate the markdown summary table from plan.json task state.
#
# Data sources used from plan/state:
#   - plan.json .tasks[].id + .tasks[].status drive table rows.
#   - progress-log.json .entries provides latest per-task summary snippet.
#
# Assumptions about incomplete plans:
#   - If plan.json is absent, no table rows are emitted.
#   - If a task has no logged entries yet, summary cell defaults to em dash.
#   - Status mapping only normalizes known values; others are shown as-is.
# Stdout: markdown table rows
_generate_plan_summary_table() {
    local plan_file="${PLAN_FILE:-plan.json}"
    if [[ ! -f "$plan_file" ]]; then
        return 0
    fi

    local ralph_dir="${RALPH_DIR:-.ralph}"
    local json_file="${ralph_dir}/progress-log.json"

    printf '| Task | Status | Summary |\n'
    printf '|------|--------|--------|\n'

    while IFS=$'\t' read -r tid tstatus; do
        local status_display
        case "$tstatus" in
            done) status_display="Done" ;;
            pending) status_display="Pending" ;;
            in_progress) status_display="In Progress" ;;
            failed) status_display="Failed" ;;
            skipped) status_display="Skipped" ;;
            *) status_display="$tstatus" ;;
        esac

        local entry_summary="—"
        if [[ -f "$json_file" ]]; then
            local found
            found="$(jq -r --arg tid "$tid" \
                '[.entries[] | select(.task_id == $tid)] | .[-1].summary // empty' \
                "$json_file" 2>/dev/null)" || true
            if [[ -n "$found" ]]; then
                entry_summary="$found"
            fi
        fi

        printf '| %s | %s | %s |\n' "$tid" "$status_display" "$entry_summary"
    done < <(jq -r '.tasks[] | "\(.id)\t\(.status)"' "$plan_file")
}

# Generate plan summary counts from plan.json for JSON progress log.
#
# Assumptions about task status fields:
#   - done -> completed bucket
#   - pending + in_progress -> pending bucket (work not yet done)
#   - failed -> failed bucket
#   - skipped -> skipped bucket
#   - Any other status is ignored by bucket counts but still contributes to total_tasks.
#
# Incomplete plan handling:
#   - Missing plan.json yields all-zero summary object so callers can continue.
# Stdout: JSON object {total_tasks, completed, pending, failed, skipped}
_generate_plan_summary_json() {
    local plan_file="${PLAN_FILE:-plan.json}"
    if [[ ! -f "$plan_file" ]]; then
        jq -n '{total_tasks: 0, completed: 0, pending: 0, failed: 0, skipped: 0}'
        return 0
    fi

    jq '{
        total_tasks: (.tasks | length),
        completed: [.tasks[] | select(.status == "done")] | length,
        pending: [.tasks[] | select(.status == "pending" or .status == "in_progress")] | length,
        failed: [.tasks[] | select(.status == "failed")] | length,
        skipped: [.tasks[] | select(.status == "skipped")] | length
    }' "$plan_file"
}

# Rebuild the markdown file: header + summary table + all existing entries + new entry.
# The summary table is regenerated from plan.json on each call, so it always reflects
# current task statuses.
# Args: $1 = md file path, $2 = new entry to append (optional)
_regenerate_progress_md() {
    local md_file="$1"
    local new_entry="${2:-}"

    # Extract existing entries (everything from first ### line onwards)
    local existing_entries=""
    if [[ -f "$md_file" ]]; then
        existing_entries="$(awk '/^### /{found=1} found{print}' "$md_file")" || true
    fi

    # Rebuild the file
    {
        printf '# Ralph Deluxe — Progress Log\n\n'
        printf '**Plan:** ralph-deluxe | **Generated:** auto-updated by orchestrator\n\n'
        _generate_plan_summary_table
        printf '\n---\n\n'

        if [[ -n "$existing_entries" ]]; then
            printf '%s\n\n' "$existing_entries"
        fi

        if [[ -n "$new_entry" ]]; then
            printf '%s\n' "$new_entry"
        fi
    } > "$md_file"
}
