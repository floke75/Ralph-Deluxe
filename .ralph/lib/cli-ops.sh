#!/usr/bin/env bash
set -euo pipefail

# cli-ops.sh — Claude Code CLI integration for Ralph Deluxe
# Wraps claude -p invocations for coding and memory iterations,
# parses structured handoff output, and manages handoff file storage.

# log() stub for standalone testing — ralph.sh provides the real one
if ! declare -f log >/dev/null 2>&1; then
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2" >&2; }
fi

# Invoke claude -p with coding MCP config for a coding iteration.
# Args: $1 = prompt, $2 = task JSON, $3 = skills file path (optional)
# Globals: RALPH_SKIP_PERMISSIONS, DRY_RUN
# Stdout: raw JSON response from claude CLI
# Returns: 0 on success, 1 on CLI failure
run_coding_iteration() {
    local prompt="$1"
    local task_json="$2"
    local skills_file="${3:-}"
    local max_turns
    max_turns=$(echo "$task_json" | jq -r '.max_turns // 20')

    local cmd_args=(
        -p
        --output-format json
        --json-schema "$(cat .ralph/config/handoff-schema.json)"
        --strict-mcp-config
        --mcp-config .ralph/config/mcp-coding.json
        --max-turns "$max_turns"
    )

    if [[ "${RALPH_SKIP_PERMISSIONS:-true}" == "true" ]]; then
        cmd_args+=(--dangerously-skip-permissions)
    fi

    if [[ -n "$skills_file" && -f "$skills_file" ]]; then
        cmd_args+=(--append-system-prompt-file "$skills_file")
    fi

    local response
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "info" "[DRY RUN] Would invoke: claude ${cmd_args[*]}"
        response='{"type":"result","subtype":"success","cost_usd":0,"duration_ms":0,"duration_api_ms":0,"is_error":false,"num_turns":1,"result":"{\"task_completed\":{\"task_id\":\"DRY-RUN\",\"summary\":\"Dry run mode\",\"fully_complete\":true},\"deviations\":[],\"bugs_encountered\":[],\"architectural_notes\":[],\"files_touched\":[],\"plan_amendments\":[],\"tests_added\":[],\"constraints_discovered\":[]}"}'
        echo "$response"
        return 0
    fi

    response=$(echo "$prompt" | claude "${cmd_args[@]}" 2>/dev/null) || {
        log "error" "Claude CLI invocation failed with exit code $?"
        return 1
    }

    echo "$response"
}

# Invoke claude -p with memory MCP config for a compaction/memory iteration.
# Args: $1 = prompt
# Globals: RALPH_SKIP_PERMISSIONS, RALPH_COMPACTION_MAX_TURNS, DRY_RUN
# Stdout: raw JSON response from claude CLI
# Returns: 0 on success, 1 on CLI failure
run_memory_iteration() {
    local prompt="$1"

    local cmd_args=(
        -p
        --output-format json
        --json-schema "$(cat .ralph/config/memory-output-schema.json)"
        --strict-mcp-config
        --mcp-config .ralph/config/mcp-memory.json
        --max-turns "${RALPH_COMPACTION_MAX_TURNS:-10}"
    )

    if [[ "${RALPH_SKIP_PERMISSIONS:-true}" == "true" ]]; then
        cmd_args+=(--dangerously-skip-permissions)
    fi

    local response
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "info" "[DRY RUN] Would invoke memory agent: claude ${cmd_args[*]}"
        response='{"type":"result","subtype":"success","cost_usd":0,"duration_ms":0,"duration_api_ms":0,"is_error":false,"num_turns":1,"result":"{\"project_summary\":\"Dry run\",\"completed_work\":[],\"active_constraints\":[],\"architectural_decisions\":[],\"file_knowledge\":[]}"}'
        echo "$response"
        return 0
    fi

    response=$(echo "$prompt" | claude "${cmd_args[@]}" 2>/dev/null) || {
        log "error" "Memory agent CLI invocation failed with exit code $?"
        return 1
    }

    echo "$response"
}

# Extract structured handoff output from Claude's JSON response envelope.
# Claude --output-format json wraps result in a JSON envelope;
# the structured output is in the "result" field as a JSON string.
# Args: $1 = raw JSON response string
# Stdout: parsed handoff JSON
# Returns: 0 on success, 1 on parse failure
parse_handoff_output() {
    local response="$1"

    local result
    result=$(echo "$response" | jq -r '.result // empty' 2>/dev/null) || {
        log "error" "Failed to parse response JSON"
        return 1
    }

    if [[ -z "$result" ]]; then
        log "error" "Empty result in response"
        return 1
    fi

    # Validate it's valid JSON
    echo "$result" | jq . >/dev/null 2>&1 || {
        log "error" "Result is not valid JSON"
        return 1
    }

    echo "$result"
}

# Write handoff JSON to a numbered file in the handoffs directory.
# Args: $1 = handoff JSON string, $2 = iteration number
# Stdout: path to the saved file
# Returns: 0 on success
save_handoff() {
    local handoff_json="$1"
    local iteration="$2"
    local handoffs_dir=".ralph/handoffs"
    local handoff_file
    handoff_file=$(printf "%s/handoff-%03d.json" "$handoffs_dir" "$iteration")

    mkdir -p "$handoffs_dir"
    echo "$handoff_json" | jq . > "$handoff_file"
    log "info" "Saved handoff to $handoff_file"
    echo "$handoff_file"
}

# Extract metadata (cost, duration, turns, error status) from the CLI response.
# Args: $1 = raw JSON response string
# Stdout: JSON object with cost_usd, duration_ms, num_turns, is_error
extract_response_metadata() {
    local response="$1"
    echo "$response" | jq '{
        cost_usd: (.cost_usd // 0),
        duration_ms: (.duration_ms // 0),
        num_turns: (.num_turns // 0),
        is_error: (.is_error // false)
    }'
}
