#!/usr/bin/env bash
set -euo pipefail

# compaction.sh — Compaction trigger and L1/L2/L3 extraction for Ralph Deluxe
# Manages hierarchical context compression and compaction scheduling.

# Source config defaults if not already loaded
RALPH_COMPACTION_THRESHOLD_BYTES="${RALPH_COMPACTION_THRESHOLD_BYTES:-32000}"
RALPH_COMPACTION_INTERVAL="${RALPH_COMPACTION_INTERVAL:-5}"
RALPH_NOVELTY_OVERLAP_THRESHOLD="${RALPH_NOVELTY_OVERLAP_THRESHOLD:-0.25}"
RALPH_NOVELTY_RECENT_HANDOFFS="${RALPH_NOVELTY_RECENT_HANDOFFS:-3}"

# log() stub for standalone testing — ralph.sh provides the real one
if ! declare -f log >/dev/null 2>&1; then
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2" >&2; }
fi

tokenize_terms() {
    local text="$1"
    echo "$text" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9]/ /g' \
        | tr ' ' '\n' \
        | sed '/^$/d' \
        | awk 'length($0) > 2' \
        | sort -u
}

build_task_term_signature() {
    local task_json="$1"
    local task_text
    task_text=$(echo "$task_json" | jq -r '[.title // "", .description // "", (.libraries // [] | join(" "))] | join(" ")')
    tokenize_terms "$task_text"
}

build_recent_handoff_term_signature() {
    local handoffs_dir="$1"
    local handoff_limit="$2"

    if [[ ! -d "$handoffs_dir" ]]; then
        return 0
    fi

    local summaries=""
    while IFS= read -r handoff_file; do
        local summary
        summary=$(jq -r '[.summary?, .task_completed.summary?, .freeform?] | map(select(type == "string" and length > 0)) | join(" ")' "$handoff_file" 2>/dev/null || true)
        summaries+=" ${summary}"
    done < <(ls -1 "$handoffs_dir"/handoff-* 2>/dev/null | sort -V | tail -n "$handoff_limit")

    tokenize_terms "$summaries"
}

calculate_term_overlap() {
    local task_terms="$1"
    local handoff_terms="$2"

    local task_count
    task_count=$(echo "$task_terms" | sed '/^$/d' | wc -l)
    if [[ "$task_count" -eq 0 ]]; then
        echo "0"
        return 0
    fi

    local intersection
    intersection=$(comm -12 <(echo "$task_terms") <(echo "$handoff_terms") | sed '/^$/d' | wc -l)
    awk -v i="$intersection" -v t="$task_count" 'BEGIN { if (t == 0) print 0; else printf "%.4f", i / t }'
}

# check_compaction_trigger — Evaluate triggers in order
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

    # Trigger 2: Novelty-based — low overlap with recent handoff summaries
    if [[ -n "$next_task_json" ]]; then
        local handoffs_dir="${RALPH_DIR:-$(dirname "$state_file")}/handoffs"
        local task_terms
        task_terms="$(build_task_term_signature "$next_task_json")"
        local handoff_terms
        handoff_terms="$(build_recent_handoff_term_signature "$handoffs_dir" "$RALPH_NOVELTY_RECENT_HANDOFFS")"

        if [[ -n "$task_terms" ]] && [[ -n "$handoff_terms" ]]; then
            local overlap
            overlap="$(calculate_term_overlap "$task_terms" "$handoff_terms")"
            if awk -v o="$overlap" -v threshold="$RALPH_NOVELTY_OVERLAP_THRESHOLD" 'BEGIN { exit !(o < threshold) }'; then
                log "info" "Compaction trigger: novelty (overlap=${overlap} < ${RALPH_NOVELTY_OVERLAP_THRESHOLD})"
                return 0
            fi
        fi
    fi

    # Trigger 3: Threshold-based — handoff bytes since compaction > threshold
    local handoff_bytes
    handoff_bytes=$(jq -r '.total_handoff_bytes_since_compaction // 0' "$state_file")
    if [[ "$handoff_bytes" -gt "$RALPH_COMPACTION_THRESHOLD_BYTES" ]]; then
        log "info" "Compaction trigger: threshold (${handoff_bytes} bytes > ${RALPH_COMPACTION_THRESHOLD_BYTES})"
        return 0
    fi

    # Trigger 4: Periodic — coding iterations since compaction >= interval
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

# build_indexer_prompt — Assemble prompt for the knowledge indexer from template + handoff data
# Args: $1 = compaction input (handoff L2 data)
# Uses globals: RALPH_DIR
# Stdout: assembled prompt string
build_indexer_prompt() {
    local compaction_input="$1"
    local template="${RALPH_DIR:-.ralph}/templates/knowledge-index-prompt.md"
    local knowledge_index="${RALPH_DIR:-.ralph}/knowledge-index.md"

    local prompt=""
    if [[ -f "$template" ]]; then
        prompt="$(cat "$template")"$'\n\n'
    fi

    # Include existing knowledge index for incremental update
    if [[ -f "$knowledge_index" ]]; then
        prompt+="## Existing Knowledge Index"$'\n'
        prompt+="$(cat "$knowledge_index")"$'\n\n'
    fi

    prompt+="## Recent Handoff Data"$'\n'
    prompt+="$compaction_input"

    echo "$prompt"
}

# run_knowledge_indexer — Reads recent handoffs, updates knowledge-index.md and knowledge-index.json
# This replaces run_compaction_cycle when in handoff-plus-index mode.
# The indexer runs a Claude iteration that writes the knowledge index files via built-in tools.
# Args: $1 = task JSON (optional, for context)
# Uses globals: RALPH_DIR, STATE_FILE, DRY_RUN
# Returns: 0 on success, 1 on failure
run_knowledge_indexer() {
    local task_json="${1:-}"
    local handoffs_dir="${RALPH_DIR:-.ralph}/handoffs"
    local state_file="${STATE_FILE:-.ralph/state.json}"

    log "info" "--- Knowledge indexer start ---"

    local compaction_input
    compaction_input="$(build_compaction_input "$handoffs_dir" "$state_file")"

    if [[ -z "$compaction_input" ]]; then
        log "info" "No new handoffs to index, skipping"
        return 0
    fi

    local indexer_prompt
    indexer_prompt="$(build_indexer_prompt "$compaction_input")"

    local knowledge_index_md="${RALPH_DIR:-.ralph}/knowledge-index.md"
    local knowledge_index_json="${RALPH_DIR:-.ralph}/knowledge-index.json"
    local backup_md
    backup_md="$(mktemp)"
    local backup_json
    backup_json="$(mktemp)"

    snapshot_knowledge_indexes "$knowledge_index_md" "$knowledge_index_json" "$backup_md" "$backup_json"

    # Run the indexer iteration via Claude CLI.
    # In real mode, Claude writes knowledge-index.md and knowledge-index.json via built-in tools.
    # In dry-run mode, run_memory_iteration returns a mock response.
    if ! run_memory_iteration "$indexer_prompt" >/dev/null; then
        log "error" "Knowledge indexer failed"
        rm -f "$backup_md" "$backup_json"
        return 1
    fi

    if ! verify_knowledge_indexes "$knowledge_index_md" "$knowledge_index_json" "$backup_md" "$backup_json"; then
        restore_knowledge_indexes "$knowledge_index_md" "$knowledge_index_json" "$backup_md" "$backup_json"
        rm -f "$backup_md" "$backup_json"
        log "error" "Knowledge index verification failed; restored prior index snapshots"
        return 1
    fi

    rm -f "$backup_md" "$backup_json"

    # Update compaction state counters
    update_compaction_state "$state_file"

    log "info" "--- Knowledge indexer end ---"
}

# snapshot_knowledge_indexes — Save current index files into temporary backups.
# Backup format: first line "1" if original file existed, "0" if it did not.
snapshot_knowledge_indexes() {
    local knowledge_index_md="$1"
    local knowledge_index_json="$2"
    local backup_md="$3"
    local backup_json="$4"

    if [[ -f "$knowledge_index_md" ]]; then
        {
            echo "1"
            cat "$knowledge_index_md"
        } > "$backup_md"
    else
        echo "0" > "$backup_md"
    fi

    if [[ -f "$knowledge_index_json" ]]; then
        {
            echo "1"
            cat "$knowledge_index_json"
        } > "$backup_json"
    else
        echo "0" > "$backup_json"
    fi
}

# restore_knowledge_indexes — Restore index files from temporary backups.
restore_knowledge_indexes() {
    local knowledge_index_md="$1"
    local knowledge_index_json="$2"
    local backup_md="$3"
    local backup_json="$4"

    restore_single_snapshot "$knowledge_index_md" "$backup_md"
    restore_single_snapshot "$knowledge_index_json" "$backup_json"
}

restore_single_snapshot() {
    local target="$1"
    local snapshot="$2"

    local existed
    existed=$(head -n 1 "$snapshot")
    if [[ "$existed" == "1" ]]; then
        tail -n +2 "$snapshot" > "$target"
    else
        rm -f "$target"
    fi
}

# verify_knowledge_indexes — Validate post-indexer output against required invariants.
verify_knowledge_indexes() {
    local knowledge_index_md="$1"
    local knowledge_index_json="$2"
    local backup_md="$3"
    local backup_json="$4"

    verify_knowledge_index_header "$knowledge_index_md" || return 1
    verify_hard_constraints_preserved "$knowledge_index_md" "$backup_md" || return 1
    verify_json_append_only "$knowledge_index_json" "$backup_json" || return 1
    verify_knowledge_index "$knowledge_index_json" || return 1
}

verify_knowledge_index_header() {
    local knowledge_index_md="$1"

    [[ -f "$knowledge_index_md" ]] || return 1
    grep -q '^# Knowledge Index$' "$knowledge_index_md" || return 1
    grep -Eq '^Last updated: iteration [0-9]+ \(.+\)$' "$knowledge_index_md" || return 1
}

verify_hard_constraints_preserved() {
    local knowledge_index_md="$1"
    local backup_md="$2"
    local existed
    existed=$(head -n 1 "$backup_md")

    [[ "$existed" == "1" ]] || return 0

    local previous_constraints
    previous_constraints=$(tail -n +2 "$backup_md" | awk '
        /^## / { if (in_constraints) exit; in_constraints=($0=="## Constraints") }
        in_constraints && /^- / {
            line=$0
            lower=tolower(line)
            if (lower ~ /must not|must|never/) print line
        }
    ')

    [[ -n "$previous_constraints" ]] || return 0

    local constraint
    while IFS= read -r constraint; do
        [[ -z "$constraint" ]] && continue
        # Check 1: exact line still present
        if grep -Fqx -- "$constraint" "$knowledge_index_md"; then
            continue
        fi
        # Check 2: memory-ID-based supersession — extract [K-...] ID from old
        # constraint and look for [supersedes: <that-id>] in the new index.
        local memory_id=""
        if [[ "$constraint" =~ \[K-[a-zA-Z0-9_-]+\] ]]; then
            memory_id="${BASH_REMATCH[0]}"
            # Strip surrounding brackets for the supersedes search
            local bare_id="${memory_id:1:${#memory_id}-2}"
            if grep -Fq "[supersedes: ${bare_id}]" "$knowledge_index_md"; then
                continue
            fi
        fi
        # Check 3: legacy format — "Superseded: <full line>"
        if grep -Fq -- "Superseded: ${constraint}" "$knowledge_index_md"; then
            continue
        fi
        log "warn" "Hard constraint dropped without supersession: ${constraint}"
        return 1
    done <<< "$previous_constraints"
}

verify_json_append_only() {
    local knowledge_index_json="$1"
    local backup_json="$2"

    [[ -f "$knowledge_index_json" ]] || return 1

    jq -e 'type == "array"' "$knowledge_index_json" >/dev/null || return 1

    # Legacy schema validation when iteration-based records are present.
    if jq -e 'length > 0 and all(.[]; has("iteration"))' "$knowledge_index_json" >/dev/null 2>&1; then
        jq -e 'all(.[]; has("iteration") and (.iteration | type == "number") and has("task") and has("summary") and has("tags"))' "$knowledge_index_json" >/dev/null || return 1
    fi

    local existed
    existed=$(head -n 1 "$backup_json")
    [[ "$existed" == "1" ]] || return 0

    local old_json
    old_json="$(tail -n +2 "$backup_json")"
    [[ -n "${old_json//[[:space:]]/}" ]] || return 0

    jq -e \
        --argjson old "$old_json" \
        '
        . as $new |
        ($new | type == "array") and
        ($new | length >= ($old | length)) and
        all($new[]; (.iteration | type == "number")) and
        (([$new[].iteration] | length) == ([$new[].iteration] | unique | length)) and
        all($old[]; . as $o | any($new[]; .iteration == $o.iteration and . == $o))
        ' "$knowledge_index_json" >/dev/null || return 1
}

# verify_knowledge_index — Validate knowledge-index.json consistency
# Checks:
# - no duplicate active memory IDs
# - supersedes references target existing memory IDs
verify_knowledge_index() {
    local knowledge_index_json="${1:-${RALPH_DIR:-.ralph}/knowledge-index.json}"

    if [[ ! -f "$knowledge_index_json" ]]; then
        log "debug" "knowledge-index.json not found, skipping verification"
        return 0
    fi

    if ! jq -e 'type == "array"' "$knowledge_index_json" >/dev/null 2>&1; then
        log "error" "knowledge-index.json must be a JSON array"
        return 1
    fi

    local duplicate_active_ids
    duplicate_active_ids=$(jq -r '
      [ .[]
        | select((.status // "active") == "active")
        | (.memory_ids // [])[]?
        | strings
      ]
      | group_by(.)
      | map(select(length > 1) | .[0])
      | join(",")
    ' "$knowledge_index_json")

    if [[ -n "$duplicate_active_ids" ]]; then
        log "error" "knowledge-index.json has duplicate active memory_ids: ${duplicate_active_ids}"
        return 1
    fi

    declare -A id_set=()
    local memory_id
    while IFS= read -r memory_id; do
        [[ -z "$memory_id" ]] && continue
        id_set["$memory_id"]=1
    done < <(jq -r '.[] | (.memory_ids // [])[]? | strings' "$knowledge_index_json" | sort -u)

    local -a missing_targets=()
    local target
    while IFS= read -r target; do
        [[ -z "$target" ]] && continue
        if [[ -z "${id_set[$target]+x}" ]]; then
            missing_targets+=("$target")
        fi
    done < <(jq -r '.[] | .supersedes? // empty | if type == "array" then .[] else . end | strings' "$knowledge_index_json")

    if (( ${#missing_targets[@]} > 0 )); then
        local missing_csv
        missing_csv=$(printf '%s\n' "${missing_targets[@]}" | sort -u | paste -sd',' -)
        log "error" "knowledge-index.json has supersedes references to unknown memory_ids: ${missing_csv}"
        return 1
    fi

    return 0
}


# update_compaction_state — Reset counters in state.json after compaction
update_compaction_state() {
    local state_file="${1:-.ralph/state.json}"

    local tmp_file
    tmp_file=$(mktemp)
    jq '.coding_iterations_since_compaction = 0 | .total_handoff_bytes_since_compaction = 0 | .last_compaction_iteration = .current_iteration' "$state_file" > "$tmp_file" && mv "$tmp_file" "$state_file"
}
