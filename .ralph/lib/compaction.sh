#!/usr/bin/env bash
set -euo pipefail

# compaction.sh — Compaction trigger and L1/L2/L3 extraction for Ralph Deluxe
# Manages hierarchical context compression and compaction scheduling.

# Source config defaults if not already loaded
RALPH_COMPACTION_THRESHOLD_BYTES="${RALPH_COMPACTION_THRESHOLD_BYTES:-32000}"
RALPH_COMPACTION_INTERVAL="${RALPH_COMPACTION_INTERVAL:-5}"

# log() stub for standalone testing — ralph.sh provides the real one
if ! declare -f log >/dev/null 2>&1; then
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2" >&2; }
fi

# check_compaction_trigger — Evaluate three triggers in order
# Returns 0 if compaction needed, 1 if not. Logs which trigger fired.
check_compaction_trigger() {
    local state_file="${1:-.ralph/state.json}"
    local next_task_json="${2:-}"

    # Trigger 1: Task-metadata-driven (highest priority)
    if [[ -n "$next_task_json" ]]; then
        local needs_docs
        needs_docs=$(echo "$next_task_json" | jq -r '.needs_docs // false')
        local lib_count
        lib_count=$(echo "$next_task_json" | jq -r '.libraries // [] | length')

        if [[ "$needs_docs" == "true" ]] || [[ "$lib_count" -gt 0 ]]; then
            log "info" "Compaction trigger: task metadata (needs_docs=${needs_docs}, libraries=${lib_count})"
            return 0
        fi
    fi

    # Trigger 2: Threshold-based — handoff bytes since compaction > threshold
    local handoff_bytes
    handoff_bytes=$(jq -r '.total_handoff_bytes_since_compaction // 0' "$state_file")
    if [[ "$handoff_bytes" -gt "$RALPH_COMPACTION_THRESHOLD_BYTES" ]]; then
        log "info" "Compaction trigger: threshold (${handoff_bytes} bytes > ${RALPH_COMPACTION_THRESHOLD_BYTES})"
        return 0
    fi

    # Trigger 3: Periodic — coding iterations since compaction >= interval
    local iterations_since
    iterations_since=$(jq -r '.coding_iterations_since_compaction // 0' "$state_file")
    if [[ "$iterations_since" -ge "$RALPH_COMPACTION_INTERVAL" ]]; then
        log "info" "Compaction trigger: periodic (${iterations_since} iterations >= ${RALPH_COMPACTION_INTERVAL})"
        return 0
    fi

    log "debug" "No compaction trigger fired (bytes=${handoff_bytes}, iterations=${iterations_since})"
    return 1
}

# extract_l1 — One-line summary from handoff JSON (~20-50 tokens)
extract_l1() {
    local handoff_file="$1"
    jq -r '"[\(.task_completed.task_id)] \(.task_completed.summary | split(". ")[0]). \(if .task_completed.fully_complete then "Complete" else "Partial" end). \(.files_touched | length) files."' "$handoff_file"
}

# extract_l2 — Key decisions object from handoff (~200-500 tokens)
extract_l2() {
    local handoff_file="$1"
    jq -r '{
        task: .task_completed.task_id,
        decisions: .architectural_notes,
        deviations: [.deviations[] | "\(.planned) → \(.actual): \(.reason)"],
        constraints: [.constraints_discovered[] | "\(.constraint): \(.workaround // .impact)"],
        failed: [.bugs_encountered[] | select(.resolved == false) | .description],
        unfinished: [.unfinished_business[] | "\(.item) (\(.priority))"]
    }' "$handoff_file"
}

# extract_l3 — Full handoff document reference (pointer to file)
extract_l3() {
    local handoff_file="$1"
    echo "$handoff_file"
}

# build_compaction_input — Assemble all handoffs since last compaction for the memory agent
build_compaction_input() {
    local handoffs_dir="${1:-.ralph/handoffs}"
    local state_file="${2:-.ralph/state.json}"

    local last_compaction_iter
    last_compaction_iter=$(jq -r '.last_compaction_iteration // 0' "$state_file")

    local combined=""
    for handoff_file in $(ls -1 "${handoffs_dir}"/handoff-*.json 2>/dev/null | sort -V); do
        local iter_num
        iter_num=$(basename "$handoff_file" | sed 's/handoff-0*//' | sed 's/\.json//')
        if [[ "$iter_num" -gt "$last_compaction_iter" ]]; then
            local l2
            l2=$(extract_l2 "$handoff_file")
            combined+="--- Iteration ${iter_num} ---"$'\n'
            combined+="${l2}"$'\n\n'
        fi
    done
    echo "$combined"
}

# update_compaction_state — Reset counters in state.json after compaction
update_compaction_state() {
    local state_file="${1:-.ralph/state.json}"

    local tmp_file
    tmp_file=$(mktemp)
    jq '.coding_iterations_since_compaction = 0 | .total_handoff_bytes_since_compaction = 0 | .last_compaction_iteration = .current_iteration' "$state_file" > "$tmp_file" && mv "$tmp_file" "$state_file"
}
