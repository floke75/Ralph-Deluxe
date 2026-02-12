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
    local transport
    if [[ -n "${RALPH_MCP_TRANSPORT:-}" ]]; then
        transport="$(echo "$RALPH_MCP_TRANSPORT" | tr '[:upper:]' '[:lower:]')"
        if [[ "$transport" != "stdio" && "$transport" != "http" ]]; then
            log "warn" "Invalid RALPH_MCP_TRANSPORT='${RALPH_MCP_TRANSPORT}'; expected stdio|http, defaulting to stdio"
            transport="stdio"
        fi
        echo "$transport"
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
#   - Claude CLI returns structured output in `.structured_output` (constrained
#     decoding via output_config.format) and conversational text in `.result`.
#   - When --json-schema is used, .structured_output contains the schema-validated
#     JSON object, and .result is typically empty.
#   - Legacy path: .result may contain JSON as a string (older CLI versions or
#     when structured_output is absent).
# Fallback chain:
#   1. Read .structured_output (constrained decoding — guaranteed schema-compliant)
#   2. Parse .result as JSON string (legacy path / manual JSON from agent)
#   3. Run handoff extraction agent (Haiku) to extract structured JSON from
#      the agent's conversational text + git diff (rich fallback)
#   4. Build minimal synthetic handoff from git metadata only (last resort)
# Args: $1 = raw JSON response string, $2 = task JSON (optional, for extraction)
# Stdout: parsed handoff JSON object
# Returns: 0 on success, 1 if no output could be extracted
# CALLERS: ralph.sh run_coding_cycle(), run_agent_coding_cycle()
parse_handoff_output() {
    local response="$1"
    local task_json="${2:-}"

    # STEP 1: Check .structured_output first (constrained decoding output).
    # WHY: When --json-schema is used, the CLI puts the schema-validated JSON
    # in .structured_output (as a JSON object, not a string). The .result field
    # is typically empty in this case.
    local structured
    structured=$(echo "$response" | jq '.structured_output // empty' 2>/dev/null) || true

    if [[ -n "$structured" && "$structured" != "null" ]]; then
        # Validate it has minimum viable content
        if echo "$structured" | jq -e '.summary // .task_completed' >/dev/null 2>&1; then
            log "info" "Handoff extracted from .structured_output (constrained decoding)"
            echo "$structured"
            return 0
        fi
        log "warn" "structured_output present but missing expected fields"
    fi

    # STEP 2: Fall back to .result (legacy path — JSON as string)
    local result
    result=$(echo "$response" | jq -r '.result // empty' 2>/dev/null) || {
        log "error" "Failed to parse response JSON"
        return 1
    }

    if [[ -n "$result" ]]; then
        if echo "$result" | jq . >/dev/null 2>&1; then
            log "info" "Handoff extracted from .result (JSON string)"
            echo "$result"
            return 0
        fi
        log "warn" "Result is not valid JSON, attempting handoff extraction"
    else
        log "warn" "Empty result in response, attempting handoff extraction"
    fi

    # Gather git state for both extraction agent and synthetic fallback
    local changed_files_status
    changed_files_status="$(git status --porcelain --untracked-files=all 2>/dev/null)"

    if [[ -z "$changed_files_status" ]]; then
        log "error" "No structured output and no file changes — coding iteration produced nothing"
        return 1
    fi

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

    # EXTRACTION PASS: Use a lightweight agent (Haiku) to extract structured
    # handoff from the coding agent's conversational text + git diff.
    # WHY: Dramatically better than synthetic — captures task_id, confidence,
    # research requests, and a real freeform narrative instead of just filenames.
    local extracted
    extracted="$(run_handoff_extraction "$result" "$files_json" "$task_json" 2>/dev/null)" || true

    if [[ -n "$extracted" ]] && echo "$extracted" | jq . >/dev/null 2>&1; then
        # Verify extraction has minimum viable fields
        local has_summary has_freeform
        has_summary="$(echo "$extracted" | jq -r '.summary // empty')"
        has_freeform="$(echo "$extracted" | jq -r '.freeform // empty')"
        if [[ -n "$has_summary" && -n "$has_freeform" && "${#has_freeform}" -ge 50 ]]; then
            log "info" "Handoff extracted by extraction agent (freeform: ${#has_freeform} chars)"
            echo "$extracted"
            return 0
        fi
        log "warn" "Extraction agent returned incomplete handoff, falling back to synthetic"
    fi

    # FINAL FALLBACK: Minimal synthetic from git metadata only.
    # WHY: Extraction agent failed or wasn't available — preserve at least file changes.
    local changed_files
    changed_files="$(echo "$files_json" | jq -r 'map(.path) | join(", ")')"
    local num_turns
    num_turns="$(echo "$response" | jq -r '.num_turns // 0' 2>/dev/null)"
    local freeform_text="Synthetic handoff: coding agent made changes but did not produce structured output. Changed files: ${changed_files}. Agent used ${num_turns} turns."

    if [[ -n "$result" ]]; then
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
}

# Run the handoff extraction agent to convert conversational text + git diff
# into a structured handoff JSON.
# WHY: The coding agent often produces useful narrative text but doesn't format
# it as JSON. A lightweight extraction pass (Haiku) recovers the structured
# fields that would otherwise be lost in synthetic fallback.
#
# Args: $1 = coding agent's text output (may be empty)
#        $2 = files_json (from git status)
#        $3 = task JSON (optional, for context)
# Stdout: extracted handoff JSON
# Returns: 0 on success, 1 on failure
# CALLER: parse_handoff_output() fallback chain
run_handoff_extraction() {
    local agent_text="${1:-}"
    local files_json="${2:-[]}"
    local task_json="${3:-}"
    local base_dir="${RALPH_DIR:-.ralph}"

    # Skip extraction if:
    # - DRY_RUN mode (keep deterministic)
    # - No agent text to extract from (nothing to work with)
    # - run_agent_iteration not available (agents.sh not sourced)
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        return 1
    fi
    if [[ -z "$agent_text" ]]; then
        log "debug" "No agent text for extraction — skipping extraction pass"
        return 1
    fi
    if ! declare -f run_agent_iteration >/dev/null 2>&1; then
        log "debug" "run_agent_iteration not available — skipping extraction pass"
        return 1
    fi

    local schema_file="${base_dir}/config/handoff-schema.json"
    local system_prompt_file="${base_dir}/templates/handoff-extraction-prompt.md"

    if [[ ! -f "$schema_file" || ! -f "$system_prompt_file" ]]; then
        log "debug" "Extraction agent schema or prompt not found — skipping"
        return 1
    fi

    # Build extraction prompt with the evidence
    local git_diff
    git_diff="$(git diff --stat HEAD 2>/dev/null || echo "(no diff available)")"

    local extraction_prompt=""
    extraction_prompt+="# Handoff Extraction Task"$'\n\n'
    extraction_prompt+="## Coding Agent Output"$'\n'
    extraction_prompt+="${agent_text:0:3000}"$'\n\n'
    extraction_prompt+="## Git Changes"$'\n'
    extraction_prompt+="### Files changed (from git status):"$'\n'
    extraction_prompt+="$(echo "$files_json" | jq -r '.[] | "- \(.action): \(.path)"')"$'\n\n'
    extraction_prompt+="### Diff summary:"$'\n'
    extraction_prompt+="${git_diff}"$'\n\n'

    if [[ -n "$task_json" ]]; then
        local task_id task_title
        task_id="$(echo "$task_json" | jq -r '.id // "unknown"' 2>/dev/null)"
        task_title="$(echo "$task_json" | jq -r '.title // "unknown"' 2>/dev/null)"
        extraction_prompt+="## Task Context"$'\n'
        extraction_prompt+="Task ID: ${task_id}"$'\n'
        extraction_prompt+="Task Title: ${task_title}"$'\n\n'
    fi

    extraction_prompt+="Extract a structured handoff JSON from the above evidence."$'\n'

    # Use Haiku for speed and cost — extraction is mechanical, not creative
    local mcp_config="${base_dir}/config/mcp-coding.json"
    if declare -f resolve_mcp_config >/dev/null 2>&1; then
        mcp_config="$(resolve_mcp_config "mcp-coding.json" "${base_dir}/config")"
    fi

    log "info" "Running handoff extraction agent (haiku)"

    local raw_response
    if ! raw_response="$(run_agent_iteration \
        "$extraction_prompt" \
        "$schema_file" \
        "$mcp_config" \
        "3" \
        "haiku" \
        "$system_prompt_file")"; then
        log "warn" "Handoff extraction agent invocation failed"
        return 1
    fi

    # Parse the extraction agent's output (same .structured_output priority)
    local extracted_result
    extracted_result="$(echo "$raw_response" | jq '.structured_output // empty' 2>/dev/null)" || true

    if [[ -z "$extracted_result" || "$extracted_result" == "null" ]]; then
        # Fall back to .result (JSON string)
        extracted_result="$(echo "$raw_response" | jq -r '.result // empty' 2>/dev/null)"
    fi

    if [[ -z "$extracted_result" ]]; then
        log "warn" "Handoff extraction agent returned empty result"
        return 1
    fi

    if ! echo "$extracted_result" | jq . >/dev/null 2>&1; then
        log "warn" "Handoff extraction agent returned non-JSON: ${extracted_result:0:200}"
        return 1
    fi

    echo "$extracted_result"
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
