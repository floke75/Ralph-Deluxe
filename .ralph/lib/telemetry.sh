#!/usr/bin/env bash
set -euo pipefail

# telemetry.sh — Append-only event stream and operator control for Ralph Deluxe
# Emits structured JSONL events to .ralph/logs/events.jsonl and processes
# operator commands (pause, resume, inject-note) from .ralph/control/commands.json.

# log() stub for standalone testing — ralph.sh provides the real one
if ! declare -f log >/dev/null 2>&1; then
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2" >&2; }
fi

# Defaults (overridden by ralph.sh globals or config)
RALPH_EVENTS_FILE="${RALPH_EVENTS_FILE:-.ralph/logs/events.jsonl}"
RALPH_CONTROL_FILE="${RALPH_CONTROL_FILE:-.ralph/control/commands.json}"
RALPH_PAUSE_POLL_SECONDS="${RALPH_PAUSE_POLL_SECONDS:-5}"

# emit_event — Append a single event to the JSONL stream
# Args: $1 = event_type (string), $2 = message (string), $3 = metadata JSON (optional)
# Writes one JSON line to RALPH_EVENTS_FILE
# Returns: 0 on success, 1 on failure
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

# init_control_file — Create the control commands file if it doesn't exist
# Ensures .ralph/control/commands.json exists with an empty pending array.
# Returns: 0
init_control_file() {
    local control_file="${RALPH_CONTROL_FILE:-.ralph/control/commands.json}"
    mkdir -p "$(dirname "$control_file")"
    if [[ ! -f "$control_file" ]]; then
        echo '{"pending":[]}' | jq . > "$control_file"
        log "debug" "Initialized control file: $control_file"
    fi
}

# read_pending_commands — Read the pending commands array from the control file
# Stdout: JSON array of pending commands (or empty array if file missing)
# Returns: 0
read_pending_commands() {
    local control_file="${RALPH_CONTROL_FILE:-.ralph/control/commands.json}"
    if [[ -f "$control_file" ]]; then
        jq -c '.pending // []' "$control_file"
    else
        echo '[]'
    fi
}

# clear_pending_commands — Reset the pending array in the control file
# Returns: 0
clear_pending_commands() {
    local control_file="${RALPH_CONTROL_FILE:-.ralph/control/commands.json}"
    if [[ -f "$control_file" ]]; then
        local tmp
        tmp="$(mktemp)"
        jq '.pending = []' "$control_file" > "$tmp" && mv "$tmp" "$control_file"
    fi
}

# process_control_commands — Read, execute, and clear pending commands
# Processes: pause, resume, inject-note, skip-task
# Sets RALPH_PAUSED=true on pause, RALPH_PAUSED=false on resume
# skip-task sets the task status to "skipped" via set_task_status() if available
# Returns: 0
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

# wait_while_paused — Block execution while RALPH_PAUSED is true
# Polls the control file for a resume command every RALPH_PAUSE_POLL_SECONDS.
# Emits a "waiting" event periodically while paused.
# Returns: 0 when resumed
wait_while_paused() {
    local poll_interval="${RALPH_PAUSE_POLL_SECONDS:-5}"

    while [[ "${RALPH_PAUSED:-false}" == "true" ]]; do
        log "info" "Paused. Waiting for resume command..."
        sleep "$poll_interval"

        # Check for new commands (specifically resume)
        process_control_commands
    done
}

# check_and_handle_commands — Convenience wrapper: process commands, then pause if needed
# Call this at the top of each iteration to handle any pending operator commands.
# Returns: 0 when ready to continue
check_and_handle_commands() {
    process_control_commands
    if [[ "${RALPH_PAUSED:-false}" == "true" ]]; then
        wait_while_paused
    fi
}

# Global pause state (set by process_control_commands)
RALPH_PAUSED="${RALPH_PAUSED:-false}"
