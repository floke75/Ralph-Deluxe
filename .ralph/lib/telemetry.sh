#!/usr/bin/env bash
set -euo pipefail

# telemetry.sh — Event stream and operator control plane
#
# PURPOSE: Two responsibilities:
# 1. Append-only JSONL event stream for observability (events.jsonl)
# 2. Operator control command queue for pause/resume/skip/inject (commands.json)
#
# The dashboard (dashboard.html) polls events.jsonl for display and POSTs to
# serve.py to enqueue commands. This module reads and executes those commands.
#
# DEPENDENCIES:
#   Called by: ralph.sh main loop (emit_event at iteration boundaries,
#             check_and_handle_commands at loop top)
#   Depends on: jq, log() from ralph.sh
#   Optionally calls: set_task_status() from plan-ops.sh (for skip-task)
#   Globals read/write: RALPH_PAUSED (controls pause/resume blocking)
#   Files written: .ralph/logs/events.jsonl (append), .ralph/control/commands.json (read+clear)
#
# CONTROL FLOW:
#   Dashboard POST → serve.py enqueue_command() → commands.json pending[]
#   ralph.sh main loop → check_and_handle_commands() → process_control_commands()
#     → reads pending[], executes each, clears pending[]
#     → if paused: wait_while_paused() blocks until resume command arrives
#
# EVENT TYPES: orchestrator_start, orchestrator_end, iteration_start, iteration_end,
#   validation_pass, validation_fail, pause, resume, note, skip_task

# log() stub for standalone testing — ralph.sh provides the real one
if ! declare -f log >/dev/null 2>&1; then
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2" >&2; }
fi

# Defaults (overridden by ralph.sh globals or config)
RALPH_EVENTS_FILE="${RALPH_EVENTS_FILE:-.ralph/logs/events.jsonl}"
RALPH_CONTROL_FILE="${RALPH_CONTROL_FILE:-.ralph/control/commands.json}"
RALPH_PAUSE_POLL_SECONDS="${RALPH_PAUSE_POLL_SECONDS:-5}"

# Append a single event to the JSONL stream.
# Args: $1 = event_type, $2 = message, $3 = metadata JSON (optional, default "{}")
# SIDE EFFECT: Appends one line to RALPH_EVENTS_FILE. Creates parent dir if needed.
emit_event() {
    local event_type="$1"
    local message="$2"
    local metadata="${3:-"{}"}"

    local events_file="${RALPH_EVENTS_FILE:-.ralph/logs/events.jsonl}"

    # Ensure parent directory exists
    mkdir -p "$(dirname "$events_file")"

    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    # Build and append the event line
    jq -cn \
        --arg ts "$timestamp" \
        --arg type "$event_type" \
        --arg msg "$message" \
        --argjson meta "$metadata" \
        '{timestamp: $ts, event: $type, message: $msg, metadata: $meta}' \
        >> "$events_file"

    log "debug" "Emitted event: $event_type — $message"
}

# Create the control commands file if it doesn't exist.
# Must be called once at orchestrator startup before the main loop.
# SIDE EFFECT: Creates .ralph/control/commands.json with empty pending array.
init_control_file() {
    local control_file="${RALPH_CONTROL_FILE:-.ralph/control/commands.json}"
    mkdir -p "$(dirname "$control_file")"
    if [[ ! -f "$control_file" ]]; then
        echo '{"pending":[]}' | jq . > "$control_file"
        log "debug" "Initialized control file: $control_file"
    fi
}

# Read the pending commands array from the control file.
# Stdout: JSON array of pending commands (or empty array if file missing)
read_pending_commands() {
    local control_file="${RALPH_CONTROL_FILE:-.ralph/control/commands.json}"
    if [[ -f "$control_file" ]]; then
        jq -c '.pending // []' "$control_file"
    else
        echo '[]'
    fi
}

# Reset the pending array in the control file after processing.
# Uses temp-file-then-rename pattern for atomicity with concurrent serve.py writes.
clear_pending_commands() {
    local control_file="${RALPH_CONTROL_FILE:-.ralph/control/commands.json}"
    if [[ -f "$control_file" ]]; then
        local tmp
        tmp="$(mktemp)"
        jq '.pending = []' "$control_file" > "$tmp" && mv "$tmp" "$control_file"
    fi
}

# Read, execute, and clear all pending commands.
# Command types: pause, resume, inject-note, skip-task
# SIDE EFFECT: Sets RALPH_PAUSED=true/false. May call set_task_status() for skip.
# INVARIANT: After return, pending[] is empty regardless of command outcomes.
process_control_commands() {
    local commands
    commands="$(read_pending_commands)"

    local count
    count="$(echo "$commands" | jq 'length')"

    if [[ "$count" -eq 0 ]]; then
        return 0
    fi

    local i=0
    while [[ "$i" -lt "$count" ]]; do
        local cmd_obj
        cmd_obj="$(echo "$commands" | jq -c ".[$i]")"
        local command
        command="$(echo "$cmd_obj" | jq -r '.command')"

        case "$command" in
            pause)
                RALPH_PAUSED=true
                emit_event "pause" "Operator requested pause"
                log "info" "Operator pause received"
                ;;
            resume)
                RALPH_PAUSED=false
                emit_event "resume" "Operator requested resume"
                log "info" "Operator resume received"
                ;;
            inject-note)
                local note
                note="$(echo "$cmd_obj" | jq -r '.note // "no note"')"
                emit_event "note" "$note"
                log "info" "Operator note injected: $note"
                ;;
            skip-task)
                local skip_task_id
                skip_task_id="$(echo "$cmd_obj" | jq -r '.task_id // "unknown"')"
                # Depends on plan-ops.sh being sourced; gracefully degrades if not
                if declare -f set_task_status >/dev/null 2>&1; then
                    local plan_file="${RALPH_PLAN_FILE:-plan.json}"
                    set_task_status "$plan_file" "$skip_task_id" "skipped"
                    emit_event "skip_task" "Operator skipped task $skip_task_id" \
                        "$(jq -cn --arg task_id "$skip_task_id" '{task_id: $task_id}')"
                    log "info" "Operator skipped task: $skip_task_id"
                else
                    emit_event "skip_task" "Skip requested for $skip_task_id (set_task_status unavailable)" \
                        "$(jq -cn --arg task_id "$skip_task_id" '{task_id: $task_id, applied: false}')"
                    log "warn" "skip-task: set_task_status not available, skip not applied"
                fi
                ;;
            *)
                log "warn" "Unknown control command: $command"
                ;;
        esac

        i=$((i + 1))
    done

    clear_pending_commands
}

# Block execution while RALPH_PAUSED is true.
# Polls control file every RALPH_PAUSE_POLL_SECONDS for a resume command.
# CALLER: check_and_handle_commands() when RALPH_PAUSED is true.
wait_while_paused() {
    local poll_interval="${RALPH_PAUSE_POLL_SECONDS:-5}"

    while [[ "${RALPH_PAUSED:-false}" == "true" ]]; do
        log "info" "Paused. Waiting for resume command..."
        sleep "$poll_interval"

        # Check for new commands (specifically resume)
        process_control_commands
    done
}

# Convenience wrapper: process pending commands, then block if paused.
# Called at the top of each main loop iteration to handle operator input.
# CALLER: ralph.sh main loop, guarded by `declare -f` check.
check_and_handle_commands() {
    process_control_commands
    if [[ "${RALPH_PAUSED:-false}" == "true" ]]; then
        wait_while_paused
    fi
}

# Global pause state (set by process_control_commands)
RALPH_PAUSED="${RALPH_PAUSED:-false}"
