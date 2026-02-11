#!/usr/bin/env bash
set -euo pipefail

# cli-ops.sh — Claude Code CLI invocation and response parsing
#
# MODULE RESPONSIBILITY BOUNDARIES
#   1) Invocation: Builds CLI args and executes `claude` in coding and memory
#      modes (including schema file selection, MCP config selection, and
#      environment-controlled options such as skip-permissions and dry-run).
#   2) Response capture: Returns the raw outer JSON envelope emitted by `claude`
#      so callers can persist/log full metadata if needed.
#   3) Parsing + handoff extraction: Performs the required double-parse for
#      `.result` (outer envelope JSON -> inner handoff JSON string) and
#      validates inner JSON before returning it.
#
# ERROR-HANDLING CONTRACT TO CALLERS
#   - On success, functions write machine-readable JSON to stdout.
#   - On operational failure (CLI invocation failure, malformed/empty output,
#     invalid inner JSON), functions log an error and return non-zero.
#   - Functions avoid partial fallback data on hard failures so callers can
#     safely retry without guessing whether output is complete.
#
# DEPENDENCIES:
#   Called by: ralph.sh run_coding_cycle(), run_agent_coding_cycle(),
#              run_compaction_cycle(); compaction.sh run_knowledge_indexer()
#   Depends on: `claude` CLI binary on PATH, jq, log() from ralph.sh
#   Reads files: .ralph/config/handoff-schema.json, .ralph/config/memory-output-schema.json,
#                .ralph/config/mcp-coding.json, .ralph/config/mcp-memory.json
#   Globals read: RALPH_SKIP_PERMISSIONS, DRY_RUN, RALPH_DEFAULT_MAX_TURNS,
#                 RALPH_COMPACTION_MAX_TURNS, RALPH_MCP_TRANSPORT, CLAUDE_CODE_REMOTE
#
# DATA FLOW:
#   run_coding_iteration(prompt, task_json, skills_file)
#     → raw JSON envelope from claude CLI
#     → parse_handoff_output() extracts .result string → re-parses as JSON
#     → save_handoff() writes to .ralph/handoffs/handoff-NNN.json
#     → extract_response_metadata() pulls cost/duration for logging
#
# CRITICAL: The claude CLI wraps structured output in a JSON envelope:
# {type, subtype, cost_usd, duration_ms, is_error, num_turns, result}.
# The "result" field contains the handoff JSON AS A STRING — requires double-parse.

# log() stub for standalone testing — ralph.sh provides the real one
if ! declare -f log >/dev/null 2>&1; then
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2" >&2; }
fi

# Detect the active MCP transport mode.
# Resolution: RALPH_MCP_TRANSPORT (explicit) > CLAUDE_CODE_REMOTE (auto) > "stdio" (default)
# Stdout: "stdio" or "http"
# CALLER: resolve_mcp_config(), ralph.sh startup log
detect_mcp_transport() {
    if [[ -n "${RALPH_MCP_TRANSPORT:-}" ]]; then
        echo "${RALPH_MCP_TRANSPORT}"
        return
    fi
    if [[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]]; then
        echo "http"
        return
    fi
    echo "stdio"
}

# Resolve an MCP config base name to a transport-appropriate file path.
# In HTTP mode, maps e.g. "mcp-context.json" → "mcp-context-http.json".
# Falls back to the base name if the HTTP variant does not exist.
# Args: $1 = base config filename (e.g. "mcp-context.json")
#        $2 = config directory (optional, default: .ralph/config)
# Stdout: path to the resolved config file
# CALLER: run_coding_iteration(), run_memory_iteration(), agents.sh
resolve_mcp_config() {
    local base_name="$1"
    local config_dir="${2:-.ralph/config}"

    local transport
    transport="$(detect_mcp_transport)"

    if [[ "$transport" == "http" ]]; then
        local http_name="${base_name%.json}-http.json"
        if [[ -f "${config_dir}/${http_name}" ]]; then
            echo "${config_dir}/${http_name}"
            return
        fi
        log "warn" "HTTP MCP config not found: ${config_dir}/${http_name}; falling back to ${base_name}"
    fi

    echo "${config_dir}/${base_name}"
}

# Invoke claude for a coding iteration.
# Command construction/environment usage:
#   - Uses system-level RALPH_DEFAULT_MAX_TURNS (default 200) as a safety-net
#     --max-turns value. Per-task turn limits are not supported — the coding
#     agent works freely until it produces structured output, and max_retries
#     controls how many full task attempts the orchestrator will make.
#   - Loads handoff schema + coding MCP config from .ralph/config.
#   - Honors env vars: RALPH_SKIP_PERMISSIONS, DRY_RUN, RALPH_DEFAULT_MAX_TURNS.
#   - Optionally appends an extra system prompt file for task-scoped skills.
# The prompt is piped to stdin; skills are injected via
# --append-system-prompt-file.
# Args: $1 = prompt, $2 = task JSON, $3 = skills file path (optional)
# Stdout: raw JSON response envelope from claude CLI
# Returns: 0 on success, 1 on CLI failure
# SIDE EFFECT: In real mode, Claude executes code and modifies the working tree.
run_coding_iteration() {
    local prompt="$1"
    local task_json="$2"
    local skills_file="${3:-}"

    local cmd_args=(
        -p
        --output-format json
        --json-schema "$(cat .ralph/config/handoff-schema.json)"
        --strict-mcp-config
        --mcp-config "$(resolve_mcp_config "mcp-coding.json")"
        --max-turns "${RALPH_DEFAULT_MAX_TURNS:-200}"
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
        response='{"type":"result","subtype":"success","cost_usd":0,"duration_ms":0,"duration_api_ms":0,"is_error":false,"num_turns":1,"result":"{\"task_completed\":{\"task_id\":\"DRY-RUN\",\"summary\":\"Dry run mode\",\"fully_complete\":true},\"deviations\":[],\"bugs_encountered\":[],\"architectural_notes\":[],\"files_touched\":[],\"plan_amendments\":[],\"tests_added\":[],\"constraints_discovered\":[],\"summary\":\"Dry run completed successfully.\",\"freeform\":\"This was a dry run iteration. No actual changes were made. The orchestrator simulated a coding pass to verify the pipeline works end-to-end.\"}"}'
        echo "$response"
        return 0
    fi

    # Defensive: ensure stderr redirect target exists even when this helper is
    # invoked outside the normal ralph.sh startup flow.
    mkdir -p "${RALPH_DIR:-.ralph}/logs"

    response=$(echo "$prompt" | claude "${cmd_args[@]}" 2>>"${RALPH_DIR:-.ralph}/logs/coding-stderr.log") || {
        # Retry-safe failure reporting: emits only deterministic log + exit code,
        # and does not create/emit partial handoff payloads.
        log "error" "Claude CLI invocation failed with exit code $?"
        return 1
    }

    echo "$response"
}

# Invoke claude for a memory/indexer iteration with memory-specific config.
# Command construction/environment usage:
#   - Loads memory output schema + memory MCP config from .ralph/config.
#   - Uses RALPH_COMPACTION_MAX_TURNS (default 10) for --max-turns.
#   - Honors env vars: RALPH_SKIP_PERMISSIONS, DRY_RUN.
# Used by legacy compaction (run_compaction_cycle) and knowledge indexer.
# Args: $1 = prompt
# Stdout: raw JSON response envelope from claude CLI
# Returns: 0 on success, 1 on CLI failure
# SIDE EFFECT: In handoff-plus-index mode, Claude writes knowledge-index.{md,json}
# directly via its built-in file tools during this call.
run_memory_iteration() {
    local prompt="$1"

    local cmd_args=(
        -p
        --output-format json
        --json-schema "$(cat .ralph/config/memory-output-schema.json)"
        --strict-mcp-config
        --mcp-config "$(resolve_mcp_config "mcp-memory.json")"
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
        # Retry-safe failure reporting: logs and exits without writing partial
        # index/handoff data from this helper.
        log "error" "Memory agent CLI invocation failed with exit code $?"
        return 1
    }

    echo "$response"
}

# Extract the structured handoff from Claude's response envelope.
# JSON/handoff extraction behavior:
#   - Assumes outer response is a JSON object with `.result` key.
#   - Requires `.result` to be a non-empty JSON-encoded string payload.
#   - Validates the inner payload with jq before returning it to callers.
# Required structural assumptions from model output:
#   - Outer envelope keys are expected to include metadata fields like
#     `cost_usd`, `duration_ms`, `num_turns`, `is_error`, plus `result`.
#   - `result` must contain an object matching the selected schema
#     (handoff-schema.json or memory-output-schema.json as configured by caller).
# Args: $1 = raw JSON response string
# Stdout: parsed handoff JSON object
# Returns: 0 on success, 1 if .result is missing/empty/invalid JSON
# CALLERS: ralph.sh run_coding_cycle(), run_compaction_cycle()
parse_handoff_output() {
    local response="$1"

    local result
    result=$(echo "$response" | jq -r '.result // empty' 2>/dev/null) || {
        log "error" "Failed to parse response JSON"
        return 1
    }

    # Try to parse as JSON first (happy path)
    if [[ -n "$result" ]]; then
        if echo "$result" | jq . >/dev/null 2>&1; then
            echo "$result"
            return 0
        fi
        log "warn" "Result is not valid JSON, attempting synthetic handoff"
    else
        log "warn" "Empty result in response, attempting synthetic handoff"
    fi

    # FALLBACK: When the coding agent spends all turns on tool use (editing files)
    # and doesn't produce structured JSON, create a synthetic handoff from git state.
    # WHY: --json-schema is not enforced when the agent exits via max_turns or
    # produces text instead of JSON after tool use.
    local changed_files_status
    changed_files_status="$(git status --porcelain --untracked-files=all 2>/dev/null)"

    if [[ -n "$changed_files_status" ]]; then
        local files_json
        files_json="$(echo "$changed_files_status" | jq -R -s '
            split("\n")
            | map(select(length > 3))
            | map(
                . as $line
                | ($line[0:2]) as $status
                | ($line[3:]) as $raw_path
                | ($raw_path | if contains(" -> ") then (split(" -> ") | .[1]) else . end) as $path
                | {
                    path: $path,
                    action: (
                        if $status == "??" or ($status | contains("A")) then "created"
                        elif ($status | contains("D")) then "deleted"
                        else "modified"
                        end
                    )
                }
            )')"
        local changed_files
        changed_files="$(echo "$files_json" | jq -r 'map(.path) | join(", ")')"
        local num_turns
        num_turns="$(echo "$response" | jq -r '.num_turns // 0' 2>/dev/null)"
        local freeform_text="Synthetic handoff: coding agent made changes but did not produce structured output. Changed files: ${changed_files}. Agent used ${num_turns} turns."

        # SIDE EFFECT: the non-JSON result text may contain useful context
        if [[ -n "$result" ]]; then
            # Truncate to keep the handoff reasonable
            freeform_text="${freeform_text} Agent output summary: ${result:0:500}"
        fi

        local synthetic
        synthetic="$(jq -cn \
            --arg summary "Synthetic handoff — agent produced code changes without structured output" \
            --arg freeform "$freeform_text" \
            --argjson files "$files_json" \
            '{
                summary: $summary,
                freeform: $freeform,
                task_completed: {task_id: "unknown", summary: "Changes made", fully_complete: false},
                deviations: [],
                bugs_encountered: [],
                architectural_notes: [],
                files_touched: $files,
                plan_amendments: [],
                tests_added: [],
                constraints_discovered: [],
                unfinished_business: [{
                    item: "Agent did not produce structured handoff",
                    reason: "Fallback synthetic handoff was generated from git status",
                    priority: "high"
                }],
                recommendations: []
            }')"
        log "warn" "Created synthetic handoff from $(echo "$files_json" | jq 'length') changed files"
        echo "$synthetic"
        return 0
    fi

    log "error" "No structured output and no file changes — coding iteration produced nothing"
    return 1
}

# Persist handoff JSON to a zero-padded numbered file.
# File naming: handoff-001.json, handoff-002.json, etc.
# Args: $1 = handoff JSON string, $2 = iteration number
# Stdout: path to saved file (consumed by ralph.sh for progress logging + byte tracking)
# SIDE EFFECT: Creates .ralph/handoffs/ if absent, writes file.
save_handoff() {
    local handoff_json="$1"
    local iteration="$2"
    local handoffs_dir="${RALPH_DIR:-.ralph}/handoffs"
    local handoff_file
    handoff_file=$(printf "%s/handoff-%03d.json" "$handoffs_dir" "$iteration")

    mkdir -p "$handoffs_dir"
    echo "$handoff_json" | jq . > "$handoff_file"
    log "info" "Saved handoff to $handoff_file"
    echo "$handoff_file"
}

# Pull cost/duration/turns from the claude response envelope for telemetry.
# Args: $1 = raw JSON response string
# Stdout: JSON object {cost_usd, duration_ms, num_turns, is_error}
extract_response_metadata() {
    local response="$1"
    echo "$response" | jq '{
        cost_usd: (.cost_usd // 0),
        duration_ms: (.duration_ms // 0),
        num_turns: (.num_turns // 0),
        is_error: (.is_error // false)
    }'
}
