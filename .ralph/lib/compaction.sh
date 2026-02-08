#!/usr/bin/env bash
set -euo pipefail

# compaction.sh — Knowledge indexing, compaction triggers, and verification
#
# PURPOSE: Manages the knowledge index lifecycle in handoff-plus-index mode.
# Three main responsibilities:
# 1. TRIGGER EVALUATION — decide whether to run the knowledge indexer before
#    a coding iteration (4 triggers in priority order)
# 2. INDEXER EXECUTION — invoke Claude to update knowledge-index.{md,json}
# 3. POST-INDEXER VERIFICATION — validate output against 4 invariants;
#    rollback to snapshots if any check fails
#
# Also provides L1/L2/L3 extraction functions used by context.sh and ralph.sh
# for hierarchical context levels.
#
# DEPENDENCIES:
#   Called by: ralph.sh main loop (check_compaction_trigger, run_knowledge_indexer)
#             context.sh (extract_l1 for L1 summaries)
#   Calls: run_memory_iteration() from cli-ops.sh (to invoke Claude indexer)
#   Depends on: jq, awk, comm, log() from ralph.sh
#   Globals read: RALPH_COMPACTION_THRESHOLD_BYTES (default 32000),
#     RALPH_COMPACTION_INTERVAL (default 5), RALPH_NOVELTY_OVERLAP_THRESHOLD (default 0.25),
#     RALPH_NOVELTY_RECENT_HANDOFFS (default 3), RALPH_DIR, STATE_FILE, DRY_RUN
#   Files read: .ralph/state.json, .ralph/handoffs/handoff-*.json,
#     .ralph/knowledge-index.md, .ralph/knowledge-index.json
#   Files written: .ralph/knowledge-index.md, .ralph/knowledge-index.json,
#     .ralph/state.json (counter reset)
#
# TRIGGER PRIORITY (first match wins):
#   1. Task metadata — needs_docs=true or libraries[] non-empty
#   2. Semantic novelty — term overlap < threshold between task and recent handoffs
#   3. Byte threshold — accumulated handoff bytes since last compaction > threshold
#   4. Periodic — coding iterations since last compaction >= interval
#
# VERIFICATION CHECKS (all must pass or changes are rolled back):
#   1. Header format — "# Knowledge Index" + "Last updated: iteration N (...)"
#   2. Hard constraints preserved — must/never lines kept or explicitly superseded
#   3. JSON append-only — new array >= old length, no entries removed, no duplicate iterations
#   4. ID consistency — no duplicate active memory_ids, supersedes targets must exist

# Source config defaults if not already loaded
RALPH_COMPACTION_THRESHOLD_BYTES="${RALPH_COMPACTION_THRESHOLD_BYTES:-32000}"
RALPH_COMPACTION_INTERVAL="${RALPH_COMPACTION_INTERVAL:-5}"
RALPH_NOVELTY_OVERLAP_THRESHOLD="${RALPH_NOVELTY_OVERLAP_THRESHOLD:-0.25}"
RALPH_NOVELTY_RECENT_HANDOFFS="${RALPH_NOVELTY_RECENT_HANDOFFS:-3}"

# log() stub for standalone testing — ralph.sh provides the real one
if ! declare -f log >/dev/null 2>&1; then
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2" >&2; }
fi

###############################################################################
# Term overlap analysis (used by novelty trigger)
###############################################################################

# Tokenize text into sorted unique lowercase terms (length > 2).
# Used to build term signatures for novelty overlap calculation.
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

# Build a term signature from task metadata (title + description + libraries).
# Args: $1 = task JSON
# Stdout: sorted unique terms, one per line
build_task_term_signature() {
    local task_json="$1"
    local task_text
    task_text=$(echo "$task_json" | jq -r '[.title // "", .description // "", (.libraries // [] | join(" "))] | join(" ")')
    tokenize_terms "$task_text"
}

# Build a term signature from recent handoff summaries.
# Args: $1 = handoffs directory, $2 = number of recent handoffs to include
# Stdout: sorted unique terms, one per line
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

# Calculate overlap ratio between two term sets.
# Overlap = |intersection| / |task_terms|
# Returns 0 (no overlap) to 1 (complete overlap).
# Args: $1 = task terms (newline-separated), $2 = handoff terms (newline-separated)
# Stdout: decimal overlap ratio (e.g., "0.3500")
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

###############################################################################
# Compaction trigger evaluation
###############################################################################

# Evaluate whether knowledge indexing should run before this iteration.
# Returns 0 if compaction needed, 1 if not. Logs which trigger fired.
# 4 triggers evaluated in priority order (first match wins).
#
# Args: $1 = state file path, $2 = next task JSON (optional)
# Returns: 0 = indexing needed, 1 = not needed
# CALLER: ralph.sh main loop, only in handoff-plus-index mode.
check_compaction_trigger() {
    local state_file="${1:-.ralph/state.json}"
    local next_task_json="${2:-}"

    # Trigger 1: Task metadata — library docs or documentation needs
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

    # Trigger 2: Semantic novelty — task diverges significantly from recent work
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

    # Trigger 3: Byte threshold — accumulated handoff data exceeds limit
    local handoff_bytes
    handoff_bytes=$(jq -r '.total_handoff_bytes_since_compaction // 0' "$state_file")
    if [[ "$handoff_bytes" -gt "$RALPH_COMPACTION_THRESHOLD_BYTES" ]]; then
        log "info" "Compaction trigger: threshold (${handoff_bytes} bytes > ${RALPH_COMPACTION_THRESHOLD_BYTES})"
        return 0
    fi

    # Trigger 4: Periodic — N coding iterations since last compaction
    local iterations_since
    iterations_since=$(jq -r '.coding_iterations_since_compaction // 0' "$state_file")
    if [[ "$iterations_since" -ge "$RALPH_COMPACTION_INTERVAL" ]]; then
        log "info" "Compaction trigger: periodic (${iterations_since} iterations >= ${RALPH_COMPACTION_INTERVAL})"
        return 0
    fi

    log "debug" "No compaction trigger fired (bytes=${handoff_bytes}, iterations=${iterations_since})"
    return 1
}

###############################################################################
# L1/L2/L3 context extraction
###############################################################################

# L1 — One-line summary (~20-50 tokens). Used for historical context lists.
# Format: [task-id] First sentence. Complete|Partial. N files.
# Args: $1 = handoff file path
# Stdout: one-line summary string
# CALLERS: context.sh get_earlier_l1_summaries()
extract_l1() {
    local handoff_file="$1"
    jq -r '"[\(.task_completed.task_id)] \(.task_completed.summary | split(". ")[0]). \(if .task_completed.fully_complete then "Complete" else "Partial" end). \(.files_touched | length) files."' "$handoff_file"
}

# L2 — Key decisions object (~200-500 tokens). Used for previous iteration context.
# Args: $1 = handoff file path
# Stdout: JSON object with task, decisions, deviations, constraints, failed, unfinished
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

# L3 — Full handoff file reference (just the path). For deep-dive lookup.
# Args: $1 = handoff file path
# Stdout: file path string
extract_l3() {
    local handoff_file="$1"
    echo "$handoff_file"
}

###############################################################################
# Knowledge indexer
###############################################################################

# Aggregate L2 data from all handoffs since last compaction.
# This becomes the input to the knowledge indexer's Claude iteration.
# Args: $1 = handoffs directory, $2 = state file
# Stdout: formatted text with L2 blocks separated by "--- Iteration N ---" headers
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

# Assemble the prompt for the knowledge indexer from template + handoff data + existing index.
# Args: $1 = compaction input (handoff L2 data)
# Stdout: assembled prompt string
build_indexer_prompt() {
    local compaction_input="$1"
    local template="${RALPH_DIR:-.ralph}/templates/knowledge-index-prompt.md"
    local knowledge_index="${RALPH_DIR:-.ralph}/knowledge-index.md"

    local prompt=""
    if [[ -f "$template" ]]; then
        prompt="$(cat "$template")"$'\n\n'
    fi

    # Include existing index so Claude can update it incrementally
    if [[ -f "$knowledge_index" ]]; then
        prompt+="## Existing Knowledge Index"$'\n'
        prompt+="$(cat "$knowledge_index")"$'\n\n'
    fi

    prompt+="## Recent Handoff Data"$'\n'
    prompt+="$compaction_input"

    echo "$prompt"
}

# Run the complete knowledge indexer cycle:
# 1. Aggregate handoff L2 data since last compaction
# 2. Snapshot existing knowledge-index files (for rollback)
# 3. Invoke Claude via run_memory_iteration() — Claude writes the index files
# 4. Verify the updated files against 4 invariants
# 5. On verification failure: restore snapshots, return error
# 6. On success: update compaction state counters
#
# Args: $1 = task JSON (optional, for context)
# Returns: 0 on success, 1 on failure (indexer error or verification failure)
# SIDE EFFECT: Updates .ralph/knowledge-index.{md,json} and .ralph/state.json
# CALLER: ralph.sh main loop, only in handoff-plus-index mode when trigger fires.
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

    # Snapshot current state for rollback on verification failure
    snapshot_knowledge_indexes "$knowledge_index_md" "$knowledge_index_json" "$backup_md" "$backup_json"

    # Claude writes knowledge-index.{md,json} via its built-in file tools
    if ! run_memory_iteration "$indexer_prompt" >/dev/null; then
        log "error" "Knowledge indexer failed"
        rm -f "$backup_md" "$backup_json"
        return 1
    fi

    # Verify against 4 invariants; rollback if any fail
    if ! verify_knowledge_indexes "$knowledge_index_md" "$knowledge_index_json" "$backup_md" "$backup_json"; then
        restore_knowledge_indexes "$knowledge_index_md" "$knowledge_index_json" "$backup_md" "$backup_json"
        rm -f "$backup_md" "$backup_json"
        log "error" "Knowledge index verification failed; restored prior index snapshots"
        return 1
    fi

    rm -f "$backup_md" "$backup_json"

    # Reset compaction counters in state.json
    update_compaction_state "$state_file"

    log "info" "--- Knowledge indexer end ---"
}

###############################################################################
# Snapshot/restore for verification rollback
###############################################################################

# Save current index files into temporary backups.
# Backup format: first line "1" if original existed, "0" if not.
# This encoding lets restore_single_snapshot() decide whether to recreate or delete.
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

# Restore index files from temporary backups on verification failure.
restore_knowledge_indexes() {
    local knowledge_index_md="$1"
    local knowledge_index_json="$2"
    local backup_md="$3"
    local backup_json="$4"

    restore_single_snapshot "$knowledge_index_md" "$backup_md"
    restore_single_snapshot "$knowledge_index_json" "$backup_json"
}

# Restore a single file from its snapshot.
# If snapshot header is "1", restore content; if "0", delete the file.
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

###############################################################################
# Post-indexer verification (4 checks, all must pass)
###############################################################################

# Run all 4 verification checks. Returns 1 on first failure.
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

# Check 1: Header format validation.
# The markdown index MUST start with "# Knowledge Index" followed by
# "Last updated: iteration N (...)".
verify_knowledge_index_header() {
    local knowledge_index_md="$1"

    [[ -f "$knowledge_index_md" ]] || return 1
    grep -q '^# Knowledge Index$' "$knowledge_index_md" || return 1
    grep -Eq '^Last updated: iteration [0-9]+ \(.+\)$' "$knowledge_index_md" || return 1
}

# Check 2: Hard constraint preservation.
# Any line under "## Constraints" in the PREVIOUS index that contains "must",
# "must not", or "never" (case-insensitive) must either:
# - Appear identically in the new index, OR
# - Be explicitly superseded via [supersedes: K-<type>-<slug>] in a new entry
#
# WHY: Hard constraints represent safety-critical decisions that should never
# be silently dropped. If a constraint is truly obsolete, the indexer must
# explicitly supersede it, creating an audit trail.
verify_hard_constraints_preserved() {
    local knowledge_index_md="$1"
    local backup_md="$2"
    local existed
    existed=$(head -n 1 "$backup_md")

    # No previous index = nothing to preserve
    [[ "$existed" == "1" ]] || return 0

    # Extract hard constraint lines from previous index
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
        # Check 2: memory-ID-based supersession
        local memory_id=""
        if [[ "$constraint" =~ \[K-[a-zA-Z0-9_-]+\] ]]; then
            memory_id="${BASH_REMATCH[0]}"
            local bare_id="${memory_id:1:${#memory_id}-2}"
            if grep -Fq "[supersedes: ${bare_id}]" "$knowledge_index_md"; then
                continue
            fi
        fi
        # Check 3: legacy supersession format
        if grep -Fq -- "Superseded: ${constraint}" "$knowledge_index_md"; then
            continue
        fi
        log "warn" "Hard constraint dropped without supersession: ${constraint}"
        return 1
    done <<< "$previous_constraints"
}

# Check 3: JSON append-only validation.
# The knowledge-index.json array must grow or stay the same size — never shrink.
# All previous entries must be preserved exactly (byte-identical).
# No duplicate iteration values allowed.
verify_json_append_only() {
    local knowledge_index_json="$1"
    local backup_json="$2"

    [[ -f "$knowledge_index_json" ]] || return 1

    jq -e 'type == "array"' "$knowledge_index_json" >/dev/null || return 1

    # Schema validation for iteration-based records
    if jq -e 'length > 0 and all(.[]; has("iteration"))' "$knowledge_index_json" >/dev/null 2>&1; then
        jq -e 'all(.[]; has("iteration") and (.iteration | type == "number") and has("task") and has("summary") and has("tags"))' "$knowledge_index_json" >/dev/null || return 1
    fi

    local existed
    existed=$(head -n 1 "$backup_json")
    [[ "$existed" == "1" ]] || return 0

    local old_json
    old_json="$(tail -n +2 "$backup_json")"
    [[ -n "${old_json//[[:space:]]/}" ]] || return 0

    # Verify: new >= old length, no duplicates, all old entries preserved
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

# Check 4: Memory ID consistency.
# - No two "active" entries may share the same memory_id
# - Every ID in a supersedes array must exist as a memory_id somewhere
#
# Memory ID format: K-<type>-<slug> (e.g., K-constraint-no-force-push)
# Types: constraint, decision, pattern, gotcha, unresolved
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

    # Check for duplicate active memory IDs
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

    # Build set of all known memory IDs
    declare -A id_set=()
    local memory_id
    while IFS= read -r memory_id; do
        [[ -z "$memory_id" ]] && continue
        id_set["$memory_id"]=1
    done < <(jq -r '.[] | (.memory_ids // [])[]? | strings' "$knowledge_index_json" | sort -u)

    # Verify all supersedes references point to existing IDs
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


# Reset compaction counters in state.json after successful indexing.
# SIDE EFFECT: Writes state.json via temp-file-then-rename.
update_compaction_state() {
    local state_file="${1:-.ralph/state.json}"

    local tmp_file
    tmp_file=$(mktemp)
    jq '.coding_iterations_since_compaction = 0 | .total_handoff_bytes_since_compaction = 0 | .last_compaction_iteration = .current_iteration' "$state_file" > "$tmp_file" && mv "$tmp_file" "$state_file"
}
