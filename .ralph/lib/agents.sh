#!/usr/bin/env bash
set -euo pipefail

# agents.sh — Agent dispatch framework for multi-agent orchestration
#
# PURPOSE:
#   Implements the agent-orchestrated mode where an LLM context agent
#   prepares prompts (pre-coding) and organizes knowledge (post-coding),
#   replacing the bash-only prompt assembly and periodic compaction of
#   earlier modes. Also provides a pluggable pass framework for optional
#   agent passes (code review, documentation, etc.).
#
# DEPENDENCIES:
#   Called by: ralph.sh main loop (agent-orchestrated mode only)
#   Calls: compaction.sh (snapshot/verify/restore_knowledge_indexes, update_compaction_state),
#          telemetry.sh (emit_event — guarded with declare -f)
#   Globals read: RALPH_DIR, STATE_FILE, PROJECT_ROOT, DRY_RUN,
#                 RALPH_SKIP_PERMISSIONS, RALPH_CONTEXT_AGENT_MODEL,
#                 RALPH_AGENT_PASSES_ENABLED
#   Globals written: none
#   Files read: .ralph/config/agents.json, .ralph/config/context-prep-schema.json,
#               .ralph/config/context-post-schema.json, .ralph/config/mcp-context.json,
#               .ralph/templates/context-prep-prompt.md, .ralph/templates/context-post-prompt.md,
#               .ralph/handoffs/handoff-NNN.json, .ralph/knowledge-index.{md,json},
#               .ralph/logs/validation/iter-N.json, .ralph/context/failure-context.md,
#               .ralph/state.json
#   Files written: .ralph/context/prepared-prompt.md (by context agent via file tools),
#                  .ralph/knowledge-index.{md,json} (by context agent via file tools)
#
# DATA FLOW:
#   Pre-coding:
#     build_context_prep_input(task, iteration, state) → manifest
#       → run_agent_iteration(system_prompt + manifest) → context agent writes prepared-prompt.md
#       → parse directive JSON → handle_prep_directives() → orchestrator proceeds/skips/pauses
#
#   Post-coding:
#     build_context_post_input(handoff, iteration, validation_result) → manifest
#       → run_agent_iteration(system_prompt + manifest) → context agent writes knowledge-index.*
#       → verify_knowledge_indexes() → parse directive JSON → handle_post_directives()
#
#   Agent passes:
#     load_agent_passes_config() → for each enabled pass matching trigger:
#       build_pass_input() → run_agent_iteration() → parse output → handle_pass_output()
#
# INVARIANTS:
#   - Context prep MUST write .ralph/context/prepared-prompt.md before returning success
#   - Context post MUST pass verify_knowledge_indexes() or changes are rolled back
#   - Agent passes are non-fatal: failures are logged but do not block the main loop
#   - All agent invocations honor DRY_RUN for testability

# log() stub for standalone testing — ralph.sh provides the real one
if ! declare -f log >/dev/null 2>&1; then
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2" >&2; }
fi

# Required section headers for prepared coding prompts.
# WHY: Agent-orchestrated mode now validates the same canonical section
# structure expected by truncation logic and downstream prompt handling.
readonly AGENT_PROMPT_REQUIRED_HEADERS=(
    "## Current Task"
    "## Failure Context"
    "## Retrieved Memory"
    "## Previous Handoff"
    "## Retrieved Project Memory"
    "## Skills"
    "## Output Instructions"
)

# Validate that a prepared prompt contains all canonical sections.
# Args: $1 = prepared prompt file path
# Returns: 0 when valid, 1 when any required section is missing
validate_prepared_prompt_structure() {
    local prompt_file="$1"

    if [[ ! -f "$prompt_file" ]]; then
        log "error" "Prepared prompt not found for validation: $prompt_file"
        return 1
    fi

    local missing=()
    local header
    for header in "${AGENT_PROMPT_REQUIRED_HEADERS[@]}"; do
        if ! grep -Fq "$header" "$prompt_file"; then
            missing+=("$header")
        fi
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        log "error" "Prepared prompt missing required sections: ${missing[*]}"
        return 1
    fi

    return 0
}

###############################################################################
# Agent invocation (generic)
###############################################################################

# Invoke a Claude CLI agent with configurable model, schema, MCP config, and max turns.
#
# WHY: Unified invocation point for all agent types (context prep, context post,
# review, documentation, etc.). Centralizes CLI arg construction and dry-run handling.
#
# Args: $1 = prompt (piped to stdin)
#        $2 = schema file path (for --json-schema)
#        $3 = MCP config file path (for --mcp-config)
#        $4 = max turns (for --max-turns)
#        $5 = model override (optional; omit or "" to use default)
#        $6 = system prompt file path (optional; for --append-system-prompt-file)
# Stdout: raw JSON response envelope from claude CLI
# Returns: 0 on success, 1 on CLI failure
# SIDE EFFECT: Agent may read/write files via Claude's built-in tools.
run_agent_iteration() {
    local prompt="$1"
    local schema_file="$2"
    local mcp_config="$3"
    local max_turns="$4"
    local model="${5:-}"
    local system_prompt_file="${6:-}"

    local cmd_args=(
        -p
        --output-format json
        --json-schema "$(cat "$schema_file")"
        --strict-mcp-config
        --mcp-config "$mcp_config"
        --max-turns "$max_turns"
    )

    if [[ -n "$model" ]]; then
        cmd_args+=(--model "$model")
    fi

    if [[ "${RALPH_SKIP_PERMISSIONS:-true}" == "true" ]]; then
        cmd_args+=(--dangerously-skip-permissions)
    fi

    if [[ -n "$system_prompt_file" && -f "$system_prompt_file" ]]; then
        cmd_args+=(--append-system-prompt-file "$system_prompt_file")
    fi

    local response
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "info" "[DRY RUN] Would invoke agent: claude ${cmd_args[*]}"
        # Return a minimal valid response for dry-run testing
        response='{"type":"result","subtype":"success","cost_usd":0,"duration_ms":0,"duration_api_ms":0,"is_error":false,"num_turns":1,"result":"{}"}'
        echo "$response"
        return 0
    fi

    mkdir -p "${RALPH_DIR:-.ralph}/logs"

    response=$(echo "$prompt" | claude "${cmd_args[@]}" 2>>"${RALPH_DIR:-.ralph}/logs/agent-stderr.log") || {
        log "error" "Agent CLI invocation failed with exit code $?"
        return 1
    }

    echo "$response"
}

# Parse structured output from an agent's response envelope.
# WHY: Same double-parse as parse_handoff_output() in cli-ops.sh — the .result
# field contains JSON as a string.
# Args: $1 = raw response JSON
# Stdout: parsed inner JSON
# Returns: 0 on success, 1 on parse failure
parse_agent_output() {
    local response="$1"

    local result
    result=$(echo "$response" | jq -r '.result // empty' 2>/dev/null) || {
        log "error" "Failed to parse agent response JSON"
        return 1
    }

    if [[ -z "$result" ]]; then
        log "error" "Empty result in agent response"
        log "error" "Response type: $(echo "$response" | jq -r '.type // "unknown"' 2>/dev/null)"
        log "error" "Response subtype: $(echo "$response" | jq -r '.subtype // "unknown"' 2>/dev/null)"
        log "error" "Is error: $(echo "$response" | jq -r '.is_error // "unknown"' 2>/dev/null)"
        log "error" "Num turns: $(echo "$response" | jq -r '.num_turns // "unknown"' 2>/dev/null)"
        echo "$response" > "${RALPH_DIR:-/tmp}/logs/debug-raw-response.json" 2>/dev/null || true
        return 1
    fi

    echo "$result" | jq . >/dev/null 2>&1 || {
        log "error" "Agent result is not valid JSON"
        log "error" "Result starts with: ${result:0:200}"
        echo "$response" > "${RALPH_DIR:-/tmp}/logs/debug-raw-response.json" 2>/dev/null || true
        return 1
    }

    echo "$result"
}

###############################################################################
# Context Preparation (pre-coding pass)
###############################################################################

# Build the input manifest for the context prep agent.
# WHY: The context agent receives lightweight pointers to files, not full content.
# It uses its built-in Read tool to access what it needs. This keeps the input
# prompt small and lets the agent exercise judgment about what to read.
#
# Args: $1 = task JSON, $2 = current iteration, $3 = mode
# Stdout: formatted manifest text
# CALLER: run_context_prep()
build_context_prep_input() {
    local task_json="$1"
    local current_iteration="$2"
    local mode="$3"
    local base_dir="${RALPH_DIR:-.ralph}"
    local handoffs_dir="${base_dir}/handoffs"

    local task_id task_title
    task_id="$(echo "$task_json" | jq -r '.id // "unknown"')"
    task_title="$(echo "$task_json" | jq -r '.title // "untitled"')"

    local manifest=""
    manifest+="# Context Preparation Input"$'\n\n'

    # Task details (inlined — small and always needed)
    manifest+="## Current Task"$'\n'
    manifest+="$(echo "$task_json" | jq -r '"ID: \(.id)\nTitle: \(.title)\nDescription: \(.description)\nAcceptance Criteria:\n" + ((.acceptance_criteria // []) | map("- " + .) | join("\n"))')"$'\n\n'

    # Task metadata for context decisions
    local retry_count max_retries skills_list libraries_list
    retry_count="$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .retry_count // 0' "${PROJECT_ROOT:-$(pwd)}/${PLAN_FILE:-plan.json}" 2>/dev/null || echo "0")"
    max_retries="$(echo "$task_json" | jq -r '.max_retries // 2')"
    skills_list="$(echo "$task_json" | jq -r '(.skills // []) | join(", ")')"
    libraries_list="$(echo "$task_json" | jq -r '(.libraries // []) | join(", ")')"

    manifest+="## Task Metadata"$'\n'
    manifest+="- Retry count: ${retry_count} of ${max_retries}"$'\n'
    manifest+="- Skills: ${skills_list:-none}"$'\n'
    manifest+="- Libraries: ${libraries_list:-none}"$'\n'
    manifest+="- Needs docs: $(echo "$task_json" | jq -r '.needs_docs // false')"$'\n\n'

    # Available context files (pointers, not content)
    manifest+="## Available Context Files"$'\n'

    # Handoff files
    local handoff_files
    handoff_files="$(find "$handoffs_dir" -maxdepth 1 -type f -name 'handoff-*.json' 2>/dev/null | sort -V)"
    if [[ -n "$handoff_files" ]]; then
        local latest_handoff
        latest_handoff="$(echo "$handoff_files" | tail -1)"
        manifest+="- Latest handoff: ${latest_handoff}"$'\n'
        local handoff_count
        handoff_count="$(echo "$handoff_files" | wc -l | tr -d ' ')"
        if [[ "$handoff_count" -gt 1 ]]; then
            local first_handoff
            first_handoff="$(echo "$handoff_files" | head -1)"
            manifest+="- All handoffs (${handoff_count} files): ${first_handoff} through ${latest_handoff}"$'\n'
        fi
    else
        manifest+="- No previous handoffs (this is the first iteration)"$'\n'
    fi

    # Knowledge index
    if [[ -f "${base_dir}/knowledge-index.md" ]]; then
        manifest+="- Knowledge index (markdown): ${base_dir}/knowledge-index.md"$'\n'
    fi
    if [[ -f "${base_dir}/knowledge-index.json" ]]; then
        manifest+="- Knowledge index (JSON): ${base_dir}/knowledge-index.json"$'\n'
    fi

    # Failure context
    if [[ -f "${base_dir}/context/failure-context.md" ]]; then
        manifest+="- Failure context (from previous failed attempt): ${base_dir}/context/failure-context.md"$'\n'
    fi

    # Validation logs
    local prev_iter=$(( current_iteration - 1 ))
    if [[ -f "${base_dir}/logs/validation/iter-${prev_iter}.json" ]]; then
        manifest+="- Previous validation log: ${base_dir}/logs/validation/iter-${prev_iter}.json"$'\n'
    fi

    # Skills directory
    if [[ -n "$skills_list" && -d "${base_dir}/skills" ]]; then
        manifest+="- Skills directory: ${base_dir}/skills/"$'\n'
    fi

    # Templates (read-only — agents must not modify these)
    manifest+=$'\n'"**IMPORTANT**: Files under .ralph/templates/ and .ralph/skills/ are READ-ONLY canonical files. Do NOT modify them. Write your output only to .ralph/context/prepared-prompt.md."$'\n\n'
    manifest+="- Output instructions template (READ-ONLY): ${base_dir}/templates/coding-prompt-footer.md"$'\n'
    if [[ "$current_iteration" -eq 1 && -f "${base_dir}/templates/first-iteration.md" ]]; then
        manifest+="- First iteration template (READ-ONLY): ${base_dir}/templates/first-iteration.md"$'\n'
    fi

    # Research requests from previous coding agent
    # WHY: The coding agent can signal request_research in its handoff — topics it
    # needs the context agent to investigate. We extract these from the latest handoff
    # and include them in the manifest so the context agent knows to act on them.
    if [[ -n "$handoff_files" ]]; then
        local latest_handoff
        latest_handoff="$(echo "$handoff_files" | tail -1)"
        local research_requests
        research_requests="$(jq -r '(.request_research // []) | .[]' "$latest_handoff" 2>/dev/null)"
        if [[ -n "$research_requests" ]]; then
            manifest+=$'\n'"## Research Requests (from coding agent)"$'\n'
            manifest+="The coding agent explicitly requested research on these topics. You MUST investigate each one and include your findings in the coding prompt:"$'\n'
            while IFS= read -r topic; do
                [[ -n "$topic" ]] && manifest+="- ${topic}"$'\n'
            done <<< "$research_requests"
        fi

        # Also surface human review requests so context agent is aware
        local human_review_needed
        human_review_needed="$(jq -r '.request_human_review.needed // false' "$latest_handoff" 2>/dev/null)"
        if [[ "$human_review_needed" == "true" ]]; then
            local review_reason
            review_reason="$(jq -r '.request_human_review.reason // "no reason given"' "$latest_handoff" 2>/dev/null)"
            manifest+=$'\n'"## Human Review Signal"$'\n'
            manifest+="The coding agent requested human review: ${review_reason}"$'\n'
            manifest+="Consider whether to recommend request_human_review as your directive."$'\n'
        fi

        # Surface confidence level for context agent awareness
        local confidence
        confidence="$(jq -r '.confidence_level // empty' "$latest_handoff" 2>/dev/null)"
        if [[ -n "$confidence" && "$confidence" != "null" && "$confidence" != "high" ]]; then
            manifest+=$'\n'"## Coding Agent Confidence"$'\n'
            manifest+="The coding agent reported **${confidence}** confidence in its last output. Consider providing more detailed guidance or research in the prompt."$'\n'
        fi
    fi

    manifest+=$'\n'"## State"$'\n'
    manifest+="- Current iteration: ${current_iteration}"$'\n'
    manifest+="- Mode: ${mode}"$'\n'
    manifest+="- Plan file: ${PLAN_FILE:-plan.json}"$'\n\n'

    # Output file path
    local output_file="${base_dir}/context/prepared-prompt.md"
    manifest+="## Output"$'\n'
    manifest+="Write the complete coding prompt to: ${output_file}"$'\n'
    manifest+="This file will be piped directly to the coding agent. It must be self-contained markdown."$'\n'

    echo "$manifest"
}

# Run the pre-coding context preparation pass.
#
# ORCHESTRATION FLOW:
#   1. Build input manifest with file pointers
#   2. Load system prompt template
#   3. Invoke context agent (writes prepared-prompt.md as side effect)
#   4. Parse directive JSON from agent output
#   5. Verify prepared-prompt.md exists and is non-empty
#
# Args: $1 = task JSON, $2 = current iteration, $3 = mode
# Stdout: directive JSON from context agent
# Returns: 0 on success, 1 on failure
# SIDE EFFECT: Context agent writes .ralph/context/prepared-prompt.md
# CALLER: ralph.sh main loop, agent-orchestrated mode, before coding iteration
run_context_prep() {
    local task_json="$1"
    local current_iteration="$2"
    local mode="$3"
    local base_dir="${RALPH_DIR:-.ralph}"

    log "info" "--- Context preparation start ---"

    local manifest
    manifest="$(build_context_prep_input "$task_json" "$current_iteration" "$mode")"

    # Load system prompt template
    local system_prompt_file="${base_dir}/templates/context-prep-prompt.md"
    if [[ ! -f "$system_prompt_file" ]]; then
        log "error" "Context prep template not found: ${system_prompt_file}"
        return 1
    fi

    # Ensure output directory exists
    mkdir -p "${base_dir}/context"

    # Remove stale prepared prompt so we can detect if the agent wrote a new one
    rm -f "${base_dir}/context/prepared-prompt.md"

    local schema_file="${base_dir}/config/context-prep-schema.json"
    local mcp_config="${base_dir}/config/mcp-context.json"
    local max_turns
    max_turns="$(jq -r '.context_agent.prep.max_turns // 10' "${base_dir}/config/agents.json" 2>/dev/null || echo "10")"
    local model="${RALPH_CONTEXT_AGENT_MODEL:-}"

    local raw_response
    if ! raw_response="$(run_agent_iteration "$manifest" "$schema_file" "$mcp_config" "$max_turns" "$model" "$system_prompt_file")"; then
        log "error" "Context prep agent invocation failed"
        return 1
    fi

    local directive_json
    local prepared_prompt="${base_dir}/context/prepared-prompt.md"

    # In dry-run mode, create a stub prepared prompt before any parse/fallback logic.
    # This ensures dry-run behavior is deterministic even when the response is non-JSON.
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        cat > "${base_dir}/context/prepared-prompt.md" <<'EOF'
## Current Task
Dry run — no prompt prepared.

## Failure Context
No failure context.

## Retrieved Memory
No memory retrieved in dry run mode.

## Previous Handoff
No previous handoff in dry run mode.

## Retrieved Project Memory
No project memory in dry run mode.

## Skills
No skills loaded in dry run mode.

## Output Instructions
Dry run mode.
EOF
        directive_json='{"action":"proceed","reason":"Dry run mode","stuck_detection":{"is_stuck":false},"context_notes":"Dry run — no real context assembly"}'
    # Parse directive — the agent should return JSON matching context-prep-schema.json.
    # FALLBACK: If the agent returned text instead of JSON (common when it spends all
    # turns on tool use), check if prepared-prompt.md was written as a side effect.
    # If it was, default to "proceed" — the agent did its job, just didn't format the output.
    elif ! directive_json="$(parse_agent_output "$raw_response")"; then
        if [[ -f "$prepared_prompt" ]] && [[ "$(wc -c < "$prepared_prompt" | tr -d ' ')" -ge 50 ]]; then
            log "warn" "Context prep agent returned text instead of JSON, but prepared-prompt.md exists — defaulting to proceed"
            directive_json='{"action":"proceed","reason":"Agent wrote prompt but did not return structured directive","stuck_detection":{"is_stuck":false}}'
        else
            log "error" "Failed to parse context prep agent output and no prepared prompt found"
            return 1
        fi
    fi

    # Verify the agent wrote the prompt file
    if [[ ! -f "$prepared_prompt" ]]; then
        log "error" "Context prep agent did not write prepared-prompt.md"
        return 1
    fi

    local prompt_size
    prompt_size=$(wc -c < "$prepared_prompt" | tr -d ' ')
    if [[ "$prompt_size" -lt 50 ]]; then
        log "error" "Prepared prompt is too small (${prompt_size} bytes) — likely malformed"
        return 1
    fi

    if ! validate_prepared_prompt_structure "$prepared_prompt"; then
        log "error" "Prepared prompt failed structural validation"
        return 1
    fi

    local action
    action="$(echo "$directive_json" | jq -r '.action // "proceed"')"
    log "info" "Context prep complete: action=${action}, prompt=${prompt_size} bytes"

    local metadata
    metadata="$(echo "$raw_response" | jq '{cost_usd: (.cost_usd // 0), duration_ms: (.duration_ms // 0), num_turns: (.num_turns // 0)}' 2>/dev/null || echo "{}")"
    log "info" "Context prep metadata: $metadata"

    log "info" "--- Context preparation end ---"
    echo "$directive_json"
}

# Read the prepared coding prompt written by the context agent.
# Args: none
# Stdout: prompt text
# Returns: 0 on success, 1 if file missing
# CALLER: ralph.sh main loop, after run_context_prep()
read_prepared_prompt() {
    local prepared_prompt="${RALPH_DIR:-.ralph}/context/prepared-prompt.md"
    if [[ ! -f "$prepared_prompt" ]]; then
        log "error" "Prepared prompt not found: $prepared_prompt"
        return 1
    fi
    cat "$prepared_prompt"
}

###############################################################################
# Context Post-Processing (post-coding pass)
###############################################################################

# Build the input manifest for the context post agent.
#
# Args: $1 = handoff file path, $2 = current iteration, $3 = task ID,
#        $4 = validation result ("passed" or "failed")
# Stdout: formatted manifest text
# CALLER: run_context_post()
build_context_post_input() {
    local handoff_file="$1"
    local current_iteration="$2"
    local task_id="$3"
    local validation_result="$4"
    local base_dir="${RALPH_DIR:-.ralph}"

    local manifest=""
    manifest+="# Knowledge Organization Input"$'\n\n'

    manifest+="## Completed Iteration"$'\n'
    manifest+="- Iteration: ${current_iteration}"$'\n'
    manifest+="- Task ID: ${task_id}"$'\n'
    manifest+="- Validation result: ${validation_result}"$'\n'
    manifest+="- Handoff file: ${handoff_file}"$'\n\n'

    # Validation details
    local validation_file="${base_dir}/logs/validation/iter-${current_iteration}.json"
    if [[ -f "$validation_file" ]]; then
        manifest+="## Validation Details"$'\n'
        manifest+="- Validation log: ${validation_file}"$'\n\n'
    fi

    # Knowledge index files
    manifest+="## Current Knowledge Index"$'\n'
    if [[ -f "${base_dir}/knowledge-index.md" ]]; then
        manifest+="- Markdown index: ${base_dir}/knowledge-index.md"$'\n'
    else
        manifest+="- Markdown index: does not exist yet (create it)"$'\n'
    fi
    if [[ -f "${base_dir}/knowledge-index.json" ]]; then
        manifest+="- JSON index: ${base_dir}/knowledge-index.json"$'\n'
    else
        manifest+="- JSON index: does not exist yet (create it)"$'\n'
    fi

    # Recent handoffs for pattern detection
    local handoff_files
    handoff_files="$(find "${base_dir}/handoffs" -maxdepth 1 -type f -name 'handoff-*.json' 2>/dev/null | sort -V | tail -5)"
    if [[ -n "$handoff_files" ]]; then
        manifest+=$'\n'"## Recent Handoffs (for pattern detection)"$'\n'
        while IFS= read -r f; do
            [[ -n "$f" ]] && manifest+="- ${f}"$'\n'
        done <<< "$handoff_files"
    fi

    # Verification rules reminder
    manifest+=$'\n'"## Verification Rules"$'\n'
    manifest+="Your changes to knowledge-index.{md,json} will be verified by verify_knowledge_indexes()."$'\n'
    manifest+="See .ralph/templates/knowledge-index-prompt.md (READ-ONLY) for full verification rules."$'\n'
    manifest+="The knowledge index prompt template is at: ${base_dir}/templates/knowledge-index-prompt.md (READ-ONLY, do not modify)"$'\n'

    echo "$manifest"
}

# Run the post-coding knowledge organization pass.
#
# ORCHESTRATION FLOW:
#   1. Build input manifest
#   2. Snapshot existing knowledge index for rollback
#   3. Invoke context agent (writes knowledge-index.* as side effect)
#   4. Verify knowledge index integrity
#   5. Parse directive JSON
#   6. Reset compaction counters on success
#
# Args: $1 = handoff file path, $2 = current iteration, $3 = task ID,
#        $4 = validation result ("passed" or "failed")
# Stdout: directive JSON from context agent
# Returns: 0 on success, 1 on failure
# SIDE EFFECT: Updates .ralph/knowledge-index.{md,json} and .ralph/state.json
# CALLER: ralph.sh main loop, agent-orchestrated mode, after coding iteration
run_context_post() {
    local handoff_file="$1"
    local current_iteration="$2"
    local task_id="$3"
    local validation_result="$4"
    local base_dir="${RALPH_DIR:-.ralph}"

    log "info" "--- Knowledge organization start ---"

    local manifest
    manifest="$(build_context_post_input "$handoff_file" "$current_iteration" "$task_id" "$validation_result")"

    local system_prompt_file="${base_dir}/templates/context-post-prompt.md"
    if [[ ! -f "$system_prompt_file" ]]; then
        log "error" "Context post template not found: ${system_prompt_file}"
        return 1
    fi

    local schema_file="${base_dir}/config/context-post-schema.json"
    local mcp_config="${base_dir}/config/mcp-context.json"
    local max_turns
    max_turns="$(jq -r '.context_agent.post.max_turns // 10' "${base_dir}/config/agents.json" 2>/dev/null || echo "10")"
    local model="${RALPH_CONTEXT_AGENT_MODEL:-}"

    # Snapshot for rollback (reuse compaction.sh machinery)
    local knowledge_index_md="${base_dir}/knowledge-index.md"
    local knowledge_index_json="${base_dir}/knowledge-index.json"
    local backup_md backup_json
    backup_md="$(mktemp)"
    backup_json="$(mktemp)"

    if declare -f snapshot_knowledge_indexes >/dev/null 2>&1; then
        snapshot_knowledge_indexes "$knowledge_index_md" "$knowledge_index_json" "$backup_md" "$backup_json"
    fi

    local raw_response
    if ! raw_response="$(run_agent_iteration "$manifest" "$schema_file" "$mcp_config" "$max_turns" "$model" "$system_prompt_file")"; then
        log "error" "Context post agent invocation failed"
        rm -f "$backup_md" "$backup_json"
        return 1
    fi

    # Verify knowledge index integrity (reuse compaction.sh verification)
    if declare -f verify_knowledge_indexes >/dev/null 2>&1; then
        if [[ -f "$knowledge_index_md" ]] || [[ -f "$knowledge_index_json" ]]; then
            if ! verify_knowledge_indexes "$knowledge_index_md" "$knowledge_index_json" "$backup_md" "$backup_json"; then
                if declare -f restore_knowledge_indexes >/dev/null 2>&1; then
                    restore_knowledge_indexes "$knowledge_index_md" "$knowledge_index_json" "$backup_md" "$backup_json"
                fi
                rm -f "$backup_md" "$backup_json"
                log "error" "Knowledge index verification failed; restored prior snapshots"
                # Non-fatal: return the directive but log the verification failure
                # The orchestrator can still proceed — knowledge update just didn't stick
            fi
        fi
    fi

    rm -f "$backup_md" "$backup_json"

    # Reset compaction counters on success
    if declare -f update_compaction_state >/dev/null 2>&1; then
        update_compaction_state "${STATE_FILE:-.ralph/state.json}"
    fi

    # Parse directive
    local directive_json
    if ! directive_json="$(parse_agent_output "$raw_response")"; then
        log "warn" "Failed to parse context post agent output; using defaults"
        directive_json='{"knowledge_updated":false,"recommended_action":"proceed","summary":"Post-processing output unparseable"}'
    fi

    local recommended_action
    recommended_action="$(echo "$directive_json" | jq -r '.recommended_action // "proceed"')"
    log "info" "Knowledge organization complete: action=${recommended_action}"

    local metadata
    metadata="$(echo "$raw_response" | jq '{cost_usd: (.cost_usd // 0), duration_ms: (.duration_ms // 0), num_turns: (.num_turns // 0)}' 2>/dev/null || echo "{}")"
    log "info" "Context post metadata: $metadata"

    log "info" "--- Knowledge organization end ---"
    echo "$directive_json"
}

###############################################################################
# Directive handling
###############################################################################

# Process the context prep agent's directive.
# Returns the action string for the orchestrator to branch on.
# Handles stuck detection logging.
#
# Args: $1 = directive JSON
# Stdout: action string ("proceed", "skip", "request_human_review", "research")
# CALLER: ralph.sh main loop
handle_prep_directives() {
    local directive_json="$1"

    local action reason
    action="$(echo "$directive_json" | jq -r '.action // "proceed"')"
    reason="$(echo "$directive_json" | jq -r '.reason // "no reason given"')"

    local is_stuck
    is_stuck="$(echo "$directive_json" | jq -r '.stuck_detection.is_stuck // false')"
    if [[ "$is_stuck" == "true" ]]; then
        local evidence suggested
        evidence="$(echo "$directive_json" | jq -r '.stuck_detection.evidence // "no evidence"')"
        suggested="$(echo "$directive_json" | jq -r '.stuck_detection.suggested_action // "none"')"
        log "warn" "STUCK DETECTED: ${evidence}"
        log "warn" "Suggested action: ${suggested}"

        if declare -f emit_event >/dev/null 2>&1; then
            emit_event "stuck_detected" "Context agent detected stuck pattern" \
                "$(jq -cn --arg evidence "$evidence" --arg suggested "$suggested" \
                '{evidence: $evidence, suggested_action: $suggested}')" || true
        fi
    fi

    local context_notes
    context_notes="$(echo "$directive_json" | jq -r '.context_notes // ""')"
    if [[ -n "$context_notes" ]]; then
        log "debug" "Context agent notes: ${context_notes}"
    fi

    case "$action" in
        proceed)
            log "info" "Context prep directive: proceed (${reason})"
            ;;
        skip)
            log "warn" "Context prep directive: skip task (${reason})"
            ;;
        request_human_review)
            log "warn" "Context prep directive: human review requested (${reason})"
            ;;
        research)
            log "info" "Context prep directive: research needed (${reason})"
            ;;
        *)
            log "warn" "Unknown context prep directive '${action}'; defaulting to proceed"
            action="proceed"
            ;;
    esac

    echo "$action"
}

# Process the context post agent's directive.
# Returns the recommended action for the orchestrator.
#
# Args: $1 = directive JSON
# Stdout: action string ("proceed", "skip_task", "modify_plan", "request_human_review", "increase_retries")
# CALLER: ralph.sh main loop
handle_post_directives() {
    local directive_json="$1"

    local action summary
    action="$(echo "$directive_json" | jq -r '.recommended_action // "proceed"')"
    summary="$(echo "$directive_json" | jq -r '.summary // "no summary"')"

    local failure_detected
    failure_detected="$(echo "$directive_json" | jq -r '.failure_pattern_detected // false')"
    if [[ "$failure_detected" == "true" ]]; then
        local pattern
        pattern="$(echo "$directive_json" | jq -r '.failure_pattern // "unknown"')"
        log "warn" "FAILURE PATTERN: ${pattern}"

        if declare -f emit_event >/dev/null 2>&1; then
            emit_event "failure_pattern" "Context agent detected failure pattern" \
                "$(jq -cn --arg pattern "$pattern" --arg action "$action" \
                '{pattern: $pattern, recommended_action: $action}')" || true
        fi
    fi

    log "info" "Knowledge org summary: ${summary}"
    log "info" "Knowledge org directive: ${action}"
    echo "$action"
}

###############################################################################
# Agent pass framework
###############################################################################

# Load agent pass configuration from agents.json.
# Stdout: JSON array of enabled pass configurations
# CALLER: run_agent_passes()
load_agent_passes_config() {
    local config_file="${RALPH_DIR:-.ralph}/config/agents.json"
    if [[ ! -f "$config_file" ]]; then
        echo "[]"
        return
    fi
    jq '[.passes[]? | select(.enabled == true)]' "$config_file" 2>/dev/null || echo "[]"
}

# Build input for a generic agent pass.
# Args: $1 = pass name, $2 = handoff file, $3 = current iteration, $4 = task ID
# Stdout: formatted input manifest
build_pass_input() {
    local pass_name="$1"
    local handoff_file="$2"
    local current_iteration="$3"
    local task_id="$4"

    local manifest=""
    manifest+="# ${pass_name} Agent Input"$'\n\n'
    manifest+="- Iteration: ${current_iteration}"$'\n'
    manifest+="- Task ID: ${task_id}"$'\n'
    manifest+="- Handoff file: ${handoff_file}"$'\n'
    manifest+="- Plan file: ${PLAN_FILE:-plan.json}"$'\n'
    manifest+="- Project root: ${PROJECT_ROOT:-$(pwd)}"$'\n'
    echo "$manifest"
}

# Check if a pass trigger condition is met.
# Args: $1 = trigger string, $2 = validation result, $3 = current iteration
# Returns: 0 if trigger fires, 1 if not
# Trigger formats: "always", "on_success", "on_failure", "periodic:N"
check_pass_trigger() {
    local trigger="$1"
    local validation_result="$2"
    local current_iteration="$3"

    case "$trigger" in
        always)
            return 0
            ;;
        on_success)
            [[ "$validation_result" == "passed" ]] && return 0 || return 1
            ;;
        on_failure)
            [[ "$validation_result" == "failed" ]] && return 0 || return 1
            ;;
        periodic:*)
            local interval="${trigger#periodic:}"
            (( current_iteration % interval == 0 )) && return 0 || return 1
            ;;
        *)
            log "warn" "Unknown pass trigger: ${trigger}"
            return 1
            ;;
    esac
}

# Run all configured agent passes matching the current trigger context.
# Passes are NON-FATAL: failures are logged but do not block the main loop.
#
# Args: $1 = handoff file, $2 = current iteration, $3 = task ID,
#        $4 = validation result ("passed" or "failed")
# Stdout: summary of pass results (JSON array)
# Returns: always 0 (passes are advisory)
# CALLER: ralph.sh main loop, agent-orchestrated mode, after context post
run_agent_passes() {
    local handoff_file="$1"
    local current_iteration="$2"
    local task_id="$3"
    local validation_result="$4"
    local base_dir="${RALPH_DIR:-.ralph}"

    local passes_config
    passes_config="$(load_agent_passes_config)"

    local pass_count
    pass_count="$(echo "$passes_config" | jq 'length')"

    if [[ "$pass_count" -eq 0 ]]; then
        log "debug" "No agent passes configured"
        return 0
    fi

    log "info" "--- Agent passes start (${pass_count} configured) ---"

    local results="[]"
    local i=0
    while [[ "$i" -lt "$pass_count" ]]; do
        local pass_json
        pass_json="$(echo "$passes_config" | jq ".[$i]")"

        local pass_name trigger pass_model pass_max_turns prompt_template schema_file mcp_config
        pass_name="$(echo "$pass_json" | jq -r '.name')"
        trigger="$(echo "$pass_json" | jq -r '.trigger // "always"')"
        pass_model="$(echo "$pass_json" | jq -r '.model // empty')"
        pass_max_turns="$(echo "$pass_json" | jq -r '.max_turns // 5')"
        prompt_template="$(echo "$pass_json" | jq -r '.prompt_template // empty')"
        schema_file="$(echo "$pass_json" | jq -r '.schema // empty')"
        mcp_config="$(echo "$pass_json" | jq -r '.mcp_config // "mcp-coding.json"')"

        if ! check_pass_trigger "$trigger" "$validation_result" "$current_iteration"; then
            log "debug" "Pass '${pass_name}' skipped (trigger '${trigger}' not met)"
            i=$((i + 1))
            continue
        fi

        log "info" "Running pass: ${pass_name} (model=${pass_model:-default})"

        local pass_input system_file
        pass_input="$(build_pass_input "$pass_name" "$handoff_file" "$current_iteration" "$task_id")"
        system_file="${base_dir}/templates/${prompt_template}"

        local pass_schema="${base_dir}/config/${schema_file}"
        local pass_mcp="${base_dir}/config/${mcp_config}"

        if [[ ! -f "$pass_schema" || ! -f "$system_file" ]]; then
            log "warn" "Pass '${pass_name}' missing schema or template, skipping"
            i=$((i + 1))
            continue
        fi

        local pass_response
        if pass_response="$(run_agent_iteration "$pass_input" "$pass_schema" "$pass_mcp" "$pass_max_turns" "$pass_model" "$system_file" 2>/dev/null)"; then
            local pass_output
            if pass_output="$(parse_agent_output "$pass_response")"; then
                results="$(echo "$results" | jq --arg name "$pass_name" --argjson output "$pass_output" '. + [{name: $name, output: $output}]')"
                log "info" "Pass '${pass_name}' completed"
            else
                log "warn" "Pass '${pass_name}' output unparseable"
            fi
        else
            log "warn" "Pass '${pass_name}' invocation failed"
        fi

        if declare -f emit_event >/dev/null 2>&1; then
            emit_event "agent_pass" "Agent pass '${pass_name}' completed" \
                "$(jq -cn --arg name "$pass_name" --argjson iter "$current_iteration" \
                '{pass_name: $name, iteration: $iter}')" || true
        fi

        i=$((i + 1))
    done

    log "info" "--- Agent passes end ---"
    echo "$results"
}
