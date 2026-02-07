#!/usr/bin/env bash
set -euo pipefail

# progress-log.sh — Auto-generated progress log for Ralph Deluxe
# Extracts progress entries from handoff JSON and writes them to both
# .ralph/progress-log.md (human-readable) and .ralph/progress-log.json
# (machine-readable for dashboard).

# log() stub for standalone testing — ralph.sh provides the real one
if ! declare -f log >/dev/null 2>&1; then
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2" >&2; }
fi

# init_progress_log — Create both progress log files with initial structure if they don't exist
# Args: none
# Globals: RALPH_DIR
# Returns: 0
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

# format_progress_entry_md — Format a handoff as a markdown progress entry
# Args: $1 = handoff file path, $2 = iteration number, $3 = task_id
# Globals: PLAN_FILE
# Stdout: markdown block
# Returns: 0
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

# format_progress_entry_json — Format a handoff as a JSON progress entry
# Args: $1 = handoff file path, $2 = iteration number, $3 = task_id
# Globals: PLAN_FILE
# Stdout: JSON object
# Returns: 0
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

# append_progress_entry — Append a progress entry to both .md and .json files
# Args: $1 = handoff file path, $2 = iteration number, $3 = task_id
# Globals: RALPH_DIR, PLAN_FILE
# Returns: 0 on success, 1 on failure
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

    # Update JSON file first (so MD summary table can read entry summaries)
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

# _resolve_task_title — Get task title from plan.json, falling back to task_id
# Args: $1 = task_id
# Globals: PLAN_FILE
# Stdout: task title string
# Returns: 0
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

# _generate_plan_summary_table — Generate the markdown summary table from plan.json
# Args: none
# Globals: PLAN_FILE, RALPH_DIR
# Stdout: markdown table rows
# Returns: 0
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

# _generate_plan_summary_json — Generate plan summary counts from plan.json
# Args: none
# Globals: PLAN_FILE
# Stdout: JSON object with task counts
# Returns: 0
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

# _regenerate_progress_md — Rebuild the markdown file with updated summary table
# Args: $1 = md file path, $2 = new entry to append (optional)
# Globals: PLAN_FILE
# Returns: 0
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
