#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# Ralph Deluxe — Bash orchestrator for Claude Code CLI
# Drives structured task plans with git-backed rollback,
# validation gates, and hierarchical context management.

###############################################################################
# Constants and defaults
###############################################################################
RALPH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$RALPH_DIR/.." && pwd)"

# Defaults (overridden by ralph.conf and CLI flags)
MAX_ITERATIONS="${RALPH_MAX_ITERATIONS:-50}"
PLAN_FILE="${RALPH_PLAN_FILE:-plan.json}"
CONFIG_FILE="${RALPH_DIR}/config/ralph.conf"
DRY_RUN=false
RESUME=false
LOG_LEVEL="${RALPH_LOG_LEVEL:-info}"
LOG_FILE="${RALPH_LOG_FILE:-.ralph/logs/ralph.log}"

###############################################################################
# Logging
###############################################################################
_log_level_num() {
    case "$1" in
        debug) echo 0 ;;
        info)  echo 1 ;;
        warn)  echo 2 ;;
        error) echo 3 ;;
        *)     echo 1 ;;
    esac
}

log() {
    local level="$1"
    shift
    local message="$*"

    local current_level
    current_level="$(_log_level_num "$LOG_LEVEL")"
    local msg_level
    msg_level="$(_log_level_num "$level")"

    if (( msg_level >= current_level )); then
        local timestamp
        timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        local level_upper
        level_upper="$(echo "$level" | tr '[:lower:]' '[:upper:]')"
        local entry="[${timestamp}] [${level_upper}] ${message}"
        echo "$entry" >> "${PROJECT_ROOT}/${LOG_FILE}"
        if [[ "$level" == "error" ]]; then
            echo "$entry" >&2
        else
            echo "$entry"
        fi
    fi
}

###############################################################################
# CLI argument parsing
###############################################################################
usage() {
    cat <<EOF
Usage: ralph.sh [OPTIONS]

Options:
  --max-iterations N   Maximum iterations to run (default: $MAX_ITERATIONS)
  --plan FILE          Path to plan.json (default: $PLAN_FILE)
  --config FILE        Path to ralph.conf (default: $CONFIG_FILE)
  --dry-run            Print what would happen without executing
  --resume             Resume from saved state
  -h, --help           Show this help message
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-iterations)
                MAX_ITERATIONS="$2"
                shift 2
                ;;
            --plan)
                PLAN_FILE="$2"
                shift 2
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --resume)
                RESUME=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log "error" "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

###############################################################################
# Configuration loading
###############################################################################
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=config/ralph.conf
        source "$CONFIG_FILE"
        log "debug" "Loaded config from $CONFIG_FILE"
    else
        log "warn" "Config file not found: $CONFIG_FILE"
    fi
}

###############################################################################
# State management
###############################################################################
STATE_FILE="${RALPH_DIR}/state.json"

read_state() {
    if [[ -f "$STATE_FILE" ]]; then
        jq -r ".$1" "$STATE_FILE"
    else
        log "error" "State file not found: $STATE_FILE"
        return 1
    fi
}

write_state() {
    local key="$1"
    local value="$2"
    local tmp
    tmp="$(mktemp)"
    jq --arg k "$key" --arg v "$value" '.[$k] = ($v | try tonumber // try (if . == "null" then null elif . == "true" then true elif . == "false" then false else . end))' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

###############################################################################
# Source library modules
###############################################################################
source_libs() {
    local lib_dir="${RALPH_DIR}/lib"
    if [[ -d "$lib_dir" ]]; then
        for lib_file in "$lib_dir"/*.sh; do
            if [[ -f "$lib_file" ]]; then
                # shellcheck source=/dev/null
                source "$lib_file"
                log "debug" "Sourced $lib_file"
            fi
        done
    else
        log "warn" "Library directory not found: $lib_dir"
    fi
}

###############################################################################
# Helper: write combined skills to a temp file for --append-system-prompt-file
###############################################################################
prepare_skills_file() {
    local task_json="$1"
    local skills_content
    skills_content="$(load_skills "$task_json" "${RALPH_DIR}/skills")"
    if [[ -n "$skills_content" ]]; then
        local skills_file
        skills_file="$(mktemp)"
        echo "$skills_content" > "$skills_file"
        echo "$skills_file"
    else
        echo ""
    fi
}

###############################################################################
# Helper: build memory agent prompt from template + compaction input
###############################################################################
build_memory_prompt() {
    local compaction_input="$1"
    local task_json="${2:-}"
    local template="${RALPH_DIR}/templates/memory-prompt.md"

    local prompt=""
    if [[ -f "$template" ]]; then
        prompt="$(cat "$template")"$'\n\n'
    fi

    prompt+="## Handoff Data to Compact"$'\n'
    prompt+="$compaction_input"

    if [[ -n "$task_json" ]]; then
        local needs_docs libraries
        needs_docs=$(echo "$task_json" | jq -r '.needs_docs // false')
        libraries=$(echo "$task_json" | jq -r '.libraries // [] | join(", ")')
        if [[ "$needs_docs" == "true" || -n "$libraries" ]]; then
            prompt+=$'\n\n'"## Library Documentation Needed"$'\n'
            prompt+="Please query Context7 for documentation on: ${libraries}"$'\n'
            prompt+="Use resolve-library-id first, then get-library-docs."
        fi
    fi

    echo "$prompt"
}

###############################################################################
# Helper: run a complete compaction cycle
###############################################################################
run_compaction_cycle() {
    local task_json="${1:-}"
    log "info" "--- Compaction cycle start ---"

    local compaction_input
    compaction_input="$(build_compaction_input "${RALPH_DIR}/handoffs" "$STATE_FILE")"

    if [[ -z "$compaction_input" ]]; then
        log "info" "No handoffs to compact, skipping"
        return 0
    fi

    local memory_prompt
    memory_prompt="$(build_memory_prompt "$compaction_input" "$task_json")"

    local raw_response
    if ! raw_response="$(run_memory_iteration "$memory_prompt")"; then
        log "error" "Memory iteration failed"
        return 1
    fi

    local compacted_json
    if ! compacted_json="$(parse_handoff_output "$raw_response")"; then
        log "error" "Failed to parse memory iteration output"
        return 1
    fi

    # Save compacted context
    mkdir -p "${RALPH_DIR}/context/compaction-history"
    local iter
    iter="$(read_state "current_iteration")"
    echo "$compacted_json" | jq . > "${RALPH_DIR}/context/compacted-latest.json"
    echo "$compacted_json" | jq . > "${RALPH_DIR}/context/compaction-history/compacted-iter-${iter}.json"
    log "info" "Saved compacted context"

    # Update state
    update_compaction_state "$STATE_FILE"

    # Log metadata
    local metadata
    metadata="$(extract_response_metadata "$raw_response")"
    log "info" "Memory iteration metadata: $metadata"

    log "info" "--- Compaction cycle end ---"
}

###############################################################################
# Helper: run a complete coding iteration cycle (prompt → CLI → parse → save)
###############################################################################
run_coding_cycle() {
    local task_json="$1"
    local current_iteration="$2"
    local task_id
    task_id="$(echo "$task_json" | jq -r '.id // "unknown"')"

    # Assemble context
    local skills_file compacted_context prev_handoff prompt

    skills_file="$(prepare_skills_file "$task_json")"

    # Get compacted context if available
    compacted_context=""
    if [[ -f "${RALPH_DIR}/context/compacted-latest.json" ]]; then
        compacted_context="$(format_compacted_context "${RALPH_DIR}/context/compacted-latest.json")"
    fi

    # Get previous handoff summary
    prev_handoff="$(get_prev_handoff_summary "${RALPH_DIR}/handoffs")"

    # Get earlier L1 summaries (iterations 2-3 back)
    local earlier_l1=""
    earlier_l1="$(get_earlier_l1_summaries "${RALPH_DIR}/handoffs")"

    # Check for failure context from a previous failed validation attempt
    local failure_context=""
    local failure_ctx_file="${RALPH_DIR}/context/failure-context.md"
    if [[ -f "$failure_ctx_file" ]]; then
        failure_context="$(cat "$failure_ctx_file")"
        rm -f "$failure_ctx_file"
        log "info" "Injecting failure context from previous attempt"
    fi

    # Collect skills content
    local skills_content=""
    if [[ -n "$skills_file" && -f "$skills_file" ]]; then
        skills_content="$(cat "$skills_file")"
    fi

    # Use first-iteration template if this is iteration 1
    if [[ "$current_iteration" -eq 1 && -f "${RALPH_DIR}/templates/first-iteration.md" ]]; then
        local first_iter_content
        first_iter_content="$(cat "${RALPH_DIR}/templates/first-iteration.md")"
        compacted_context="${first_iter_content}"$'\n\n'"${compacted_context}"
    fi

    # Build prompt with priority-ordered context
    prompt="$(build_coding_prompt "$task_json" "$compacted_context" "$prev_handoff" "$skills_content" "$failure_context" "$earlier_l1")"

    # Apply token budget truncation
    prompt="$(truncate_to_budget "$prompt")"

    log "info" "Prompt assembled ($(estimate_tokens "$prompt") estimated tokens)"

    # Run the coding iteration via Claude CLI
    local raw_response
    if ! raw_response="$(run_coding_iteration "$prompt" "$task_json" "$skills_file")"; then
        log "error" "Coding iteration failed for $task_id"
        [[ -n "$skills_file" && -f "$skills_file" ]] && rm -f "$skills_file"
        return 1
    fi

    # Clean up skills temp file
    [[ -n "$skills_file" && -f "$skills_file" ]] && rm -f "$skills_file"

    # Parse the structured handoff output
    local handoff_json
    if ! handoff_json="$(parse_handoff_output "$raw_response")"; then
        log "error" "Failed to parse handoff output for $task_id"
        return 1
    fi

    # Save the handoff
    local handoff_file
    handoff_file="$(save_handoff "$handoff_json" "$current_iteration")"

    # Update handoff byte tracking for compaction triggers
    local handoff_bytes
    handoff_bytes="$(wc -c < "$handoff_file" | tr -d ' ')"
    local prev_bytes
    prev_bytes="$(read_state "total_handoff_bytes_since_compaction")"
    write_state "total_handoff_bytes_since_compaction" "$(( prev_bytes + handoff_bytes ))"

    # Increment coding iterations since compaction
    local prev_iters
    prev_iters="$(read_state "coding_iterations_since_compaction")"
    write_state "coding_iterations_since_compaction" "$(( prev_iters + 1 ))"

    # Log response metadata
    local metadata
    metadata="$(extract_response_metadata "$raw_response")"
    log "info" "Coding iteration metadata: $metadata"

    # Return handoff file path via stdout
    echo "$handoff_file"
}

###############################################################################
# Helper: increment retry count for a task in the plan
###############################################################################
increment_retry_count() {
    local plan_file="$1"
    local task_id="$2"
    local tmp
    tmp="$(mktemp)"
    jq --arg id "$task_id" \
        '.tasks = [.tasks[] | if .id == $id then .retry_count = ((.retry_count // 0) + 1) else . end]' \
        "$plan_file" > "$tmp" && mv "$tmp" "$plan_file"
}

###############################################################################
# Signal handling — graceful shutdown
###############################################################################
SHUTTING_DOWN=false

shutdown_handler() {
    if [[ "$SHUTTING_DOWN" == "true" ]]; then
        return
    fi
    SHUTTING_DOWN=true
    log "warn" "Received shutdown signal, saving state and exiting"
    write_state "status" "interrupted"
    log "info" "State saved. Exiting gracefully."
    exit 130
}

trap shutdown_handler SIGINT SIGTERM

###############################################################################
# Main loop
###############################################################################
main() {
    parse_args "$@"
    load_config

    cd "$PROJECT_ROOT"

    log "info" "Ralph Deluxe starting (dry_run=$DRY_RUN, resume=$RESUME)"

    local remaining
    remaining="$(count_remaining_tasks "$PLAN_FILE" 2>/dev/null || echo "?")"
    log "info" "Plan: $PLAN_FILE ($remaining tasks remaining)"

    # Read current state
    local current_iteration
    current_iteration="$(read_state "current_iteration")"

    if [[ "$RESUME" == "true" ]]; then
        log "info" "Resuming from iteration $current_iteration"
    else
        current_iteration=0
        write_state "current_iteration" "0"
        write_state "status" "running"
        write_state "started_at" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    fi

    # Source library modules (after config, before loop)
    source_libs

    # Ensure clean git state before starting
    if [[ "$DRY_RUN" == "false" ]]; then
        ensure_clean_state
    fi

    log "info" "Starting main loop (max_iterations=$MAX_ITERATIONS)"

    while (( current_iteration < MAX_ITERATIONS )); do
        # Check for shutdown signal
        if [[ "$SHUTTING_DOWN" == "true" ]]; then
            break
        fi

        # Check if plan is complete
        if is_plan_complete "$PLAN_FILE"; then
            log "info" "All tasks complete. Exiting."
            write_state "status" "complete"
            break
        fi

        # Get next pending task
        local task_json
        task_json="$(get_next_task "$PLAN_FILE")"

        if [[ -z "$task_json" || "$task_json" == "{}" || "$task_json" == "null" ]]; then
            log "info" "No pending tasks found (possible blocked dependencies). Exiting."
            write_state "status" "blocked"
            break
        fi

        local task_id task_title
        task_id="$(echo "$task_json" | jq -r '.id // "unknown"')"
        task_title="$(echo "$task_json" | jq -r '.title // "untitled"')"

        current_iteration=$((current_iteration + 1))
        write_state "current_iteration" "$current_iteration"
        write_state "last_task_id" "$task_id"

        log "info" "=========================================="
        log "info" "Iteration $current_iteration: $task_id — $task_title"
        log "info" "=========================================="

        # === DRY RUN MODE ===
        if [[ "$DRY_RUN" == "true" ]]; then
            log "info" "[DRY RUN] Processing task $task_id"

            # Still run compaction check in dry-run to test triggers
            if check_compaction_trigger "$STATE_FILE" "$task_json" 2>/dev/null; then
                log "info" "[DRY RUN] Compaction would be triggered"
                run_compaction_cycle "$task_json" || true
            fi

            # Run coding cycle in dry-run (CLI returns mock response)
            set_task_status "$PLAN_FILE" "$task_id" "in_progress"
            local handoff_file
            handoff_file="$(run_coding_cycle "$task_json" "$current_iteration")" || true
            set_task_status "$PLAN_FILE" "$task_id" "done"
            continue
        fi

        # === REAL MODE ===

        # Step 1: Check compaction trigger
        if check_compaction_trigger "$STATE_FILE" "$task_json"; then
            log "info" "Compaction triggered, running memory iteration"
            run_compaction_cycle "$task_json" || {
                log "warn" "Compaction failed, continuing without updated context"
            }
        fi

        # Step 2: Mark task as in-progress
        set_task_status "$PLAN_FILE" "$task_id" "in_progress"

        # Step 3: Create git checkpoint
        local checkpoint
        checkpoint="$(create_checkpoint)"
        log "info" "Checkpoint: ${checkpoint:0:8}"

        # Step 4: Run the coding cycle (prompt → CLI → parse → save)
        local handoff_file=""
        if ! handoff_file="$(run_coding_cycle "$task_json" "$current_iteration")"; then
            log "error" "Coding cycle failed for $task_id"
            rollback_to_checkpoint "$checkpoint"
            set_task_status "$PLAN_FILE" "$task_id" "pending"
            increment_retry_count "$PLAN_FILE" "$task_id"

            local retry_count max_retries
            retry_count="$(echo "$task_json" | jq -r '.retry_count // 0')"
            max_retries="$(echo "$task_json" | jq -r '.max_retries // 2')"
            if (( retry_count >= max_retries )); then
                log "error" "Task $task_id exceeded max retries ($max_retries)"
                set_task_status "$PLAN_FILE" "$task_id" "failed"
            fi
            log "info" "=== End iteration $current_iteration (coding failed) ==="
            continue
        fi

        # Step 5: Run validation gate
        if run_validation "$current_iteration"; then
            log "info" "Validation PASSED for iteration $current_iteration"

            # Step 6a: Commit successful iteration
            commit_iteration "$current_iteration" "$task_id" "passed validation"
            set_task_status "$PLAN_FILE" "$task_id" "done"

            # Step 7: Apply plan amendments from handoff (if any)
            if [[ -n "$handoff_file" && -f "$handoff_file" ]]; then
                apply_amendments "$PLAN_FILE" "$handoff_file" "$task_id" || {
                    log "warn" "Amendment application had issues, continuing"
                }
            fi

            log "info" "Remaining tasks: $(count_remaining_tasks "$PLAN_FILE")"
        else
            log "warn" "Validation FAILED for iteration $current_iteration"

            # Step 6b: Rollback on validation failure
            rollback_to_checkpoint "$checkpoint"

            # Increment retry count
            increment_retry_count "$PLAN_FILE" "$task_id"

            local retry_count max_retries
            retry_count="$(echo "$task_json" | jq -r '.retry_count // 0')"
            max_retries="$(echo "$task_json" | jq -r '.max_retries // 2')"

            if (( retry_count >= max_retries )); then
                log "error" "Task $task_id exceeded max retries ($max_retries), marking failed"
                set_task_status "$PLAN_FILE" "$task_id" "failed"
            else
                log "info" "Will retry task $task_id (attempt $((retry_count + 1))/$max_retries)"
                set_task_status "$PLAN_FILE" "$task_id" "pending"
            fi

            # Save failure context for the retry iteration's prompt
            local validation_file=".ralph/logs/validation/iter-${current_iteration}.json"
            if [[ -f "$validation_file" ]]; then
                local failure_ctx
                failure_ctx="$(generate_failure_context "$validation_file")"
                if [[ -n "$failure_ctx" ]]; then
                    mkdir -p "${RALPH_DIR}/context"
                    echo "$failure_ctx" > "${RALPH_DIR}/context/failure-context.md"
                    log "info" "Failure context saved for retry"
                fi
            fi
        fi

        log "info" "=== End iteration $current_iteration ==="

        # Rate limit protection: delay between iterations
        local delay="${RALPH_MIN_DELAY_SECONDS:-30}"
        if [[ "$delay" -gt 0 ]]; then
            log "debug" "Waiting ${delay}s before next iteration (rate limit protection)"
            sleep "$delay"
        fi
    done

    if (( current_iteration >= MAX_ITERATIONS )); then
        log "warn" "Reached max iterations ($MAX_ITERATIONS)"
        write_state "status" "max_iterations_reached"
    fi

    log "info" "Ralph Deluxe finished ($(count_remaining_tasks "$PLAN_FILE" 2>/dev/null || echo "?") tasks remaining)"
}

# Run main unless being sourced (for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
