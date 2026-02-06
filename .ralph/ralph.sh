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
# Stub functions (replaced by lib modules in later phases)
###############################################################################
if ! declare -f build_coding_prompt > /dev/null 2>&1; then
build_coding_prompt() {
    log "debug" "STUB: build_coding_prompt called"
    return 0
}
fi

if ! declare -f run_coding_iteration > /dev/null 2>&1; then
run_coding_iteration() {
    log "debug" "STUB: run_coding_iteration called"
    return 0
}
fi

if ! declare -f run_memory_iteration > /dev/null 2>&1; then
run_memory_iteration() {
    log "debug" "STUB: run_memory_iteration called"
    return 0
}
fi

if ! declare -f run_validation > /dev/null 2>&1; then
run_validation() {
    log "debug" "STUB: run_validation called"
    return 0
}
fi

if ! declare -f create_checkpoint > /dev/null 2>&1; then
create_checkpoint() {
    log "debug" "STUB: create_checkpoint called"
    echo "stub-checkpoint"
}
fi

if ! declare -f rollback_to_checkpoint > /dev/null 2>&1; then
rollback_to_checkpoint() {
    log "debug" "STUB: rollback_to_checkpoint called"
    return 0
}
fi

if ! declare -f commit_iteration > /dev/null 2>&1; then
commit_iteration() {
    log "debug" "STUB: commit_iteration called"
    return 0
}
fi

if ! declare -f apply_amendments > /dev/null 2>&1; then
apply_amendments() {
    log "debug" "STUB: apply_amendments called"
    return 0
}
fi

if ! declare -f check_compaction_trigger > /dev/null 2>&1; then
check_compaction_trigger() {
    log "debug" "STUB: check_compaction_trigger called"
    return 1
}
fi

if ! declare -f ensure_clean_state > /dev/null 2>&1; then
ensure_clean_state() {
    log "debug" "STUB: ensure_clean_state called"
    return 0
}
fi

if ! declare -f get_next_task > /dev/null 2>&1; then
get_next_task() {
    log "debug" "STUB: get_next_task called"
    echo "{}"
}
fi

if ! declare -f set_task_status > /dev/null 2>&1; then
set_task_status() {
    log "debug" "STUB: set_task_status called"
    return 0
}
fi

if ! declare -f is_plan_complete > /dev/null 2>&1; then
is_plan_complete() {
    log "debug" "STUB: is_plan_complete called"
    return 0
}
fi

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
            log "info" "No pending tasks found. Exiting."
            write_state "status" "complete"
            break
        fi

        local task_id
        task_id="$(echo "$task_json" | jq -r '.id // "unknown"')"

        current_iteration=$((current_iteration + 1))
        write_state "current_iteration" "$current_iteration"
        write_state "last_task_id" "$task_id"

        log "info" "=== Iteration $current_iteration: $task_id ==="

        if [[ "$DRY_RUN" == "true" ]]; then
            log "info" "[DRY RUN] Would process task $task_id"
            log "info" "[DRY RUN] Would check compaction trigger"
            log "info" "[DRY RUN] Would create checkpoint"
            log "info" "[DRY RUN] Would run coding iteration"
            log "info" "[DRY RUN] Would run validation"
            log "info" "[DRY RUN] Would commit or rollback"
            set_task_status "$PLAN_FILE" "$task_id" "done"
            continue
        fi

        # Check if compaction is needed before coding iteration
        if check_compaction_trigger "$STATE_FILE" "$task_json"; then
            log "info" "Compaction triggered, running memory iteration"
            run_memory_iteration
        fi

        # Mark task as in-progress
        set_task_status "$PLAN_FILE" "$task_id" "in_progress"

        # Create git checkpoint
        local checkpoint
        checkpoint="$(create_checkpoint)"
        log "info" "Checkpoint: $checkpoint"

        # Build prompt and run coding iteration
        local prompt
        prompt="$(build_coding_prompt "$task_json")"
        run_coding_iteration "$prompt" "$task_json"

        # Run validation
        if run_validation "$current_iteration"; then
            log "info" "Validation passed for iteration $current_iteration"
            commit_iteration "$current_iteration" "$task_id" "passed validation"
            set_task_status "$PLAN_FILE" "$task_id" "done"

            # Apply any plan amendments from the handoff
            local handoff_file="${RALPH_DIR}/handoffs/handoff-$(printf '%03d' "$current_iteration").json"
            if [[ -f "$handoff_file" ]]; then
                apply_amendments "$PLAN_FILE" "$handoff_file" "$task_id"
            fi
        else
            log "warn" "Validation failed for iteration $current_iteration, rolling back"
            rollback_to_checkpoint "$checkpoint"

            local retry_count
            retry_count="$(echo "$task_json" | jq -r '.retry_count // 0')"
            local max_retries
            max_retries="$(echo "$task_json" | jq -r '.max_retries // 2')"

            if (( retry_count >= max_retries )); then
                log "error" "Task $task_id exceeded max retries ($max_retries)"
                set_task_status "$PLAN_FILE" "$task_id" "failed"
            else
                log "info" "Will retry task $task_id (attempt $((retry_count + 1))/$max_retries)"
            fi
        fi

        log "info" "=== End iteration $current_iteration ==="
    done

    if (( current_iteration >= MAX_ITERATIONS )); then
        log "warn" "Reached max iterations ($MAX_ITERATIONS)"
        write_state "status" "max_iterations_reached"
    fi

    log "info" "Ralph Deluxe finished"
}

# Run main unless being sourced (for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
