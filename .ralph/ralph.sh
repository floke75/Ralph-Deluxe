#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

###############################################################################
# ralph.sh — Main orchestration entrypoint
#
# ORCHESTRATION PHASES (high level):
#   startup -> iterate tasks -> finalize.
#   - startup: parse CLI/config, resolve mode precedence, source runtime modules,
#     initialize telemetry/progress hooks, and verify clean git state.
#   - iterate: select next runnable task, optionally run compaction/indexing,
#     checkpoint git, run coding cycle, gate on validation, then either commit
#     and advance or rollback and re-queue/fail the task.
#   - finalize: persist terminal status (complete/blocked/max-iterations/
#     interrupted), emit final telemetry, and exit.
#
# MODULE SOURCING & DEPENDENCIES:
#   This file owns cross-module sequencing and state transitions only.
#   It sources .ralph/lib/*.sh after config load so modules read resolved config
#   globals at source time. Module internals (prompt assembly, validation
#   implementation, compaction heuristics, git primitives, plan mutation, etc.)
#   are documented in those module headers and intentionally not duplicated here.
#
# SIGNALS & SHUTDOWN:
#   SIGINT/SIGTERM route through shutdown_handler(), which marks state as
#   interrupted, emits an end event when telemetry is available, and exits 130.
#   A reentrancy guard prevents double cleanup if multiple signals arrive.
#
# TESTABILITY:
#   main() is guarded at EOF so tests can source this file without running the
#   loop, then invoke helpers directly.
###############################################################################

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
MODE=""  # handoff-only | handoff-plus-index | agent-orchestrated (set by CLI, config, or default)

###############################################################################
# Logging
###############################################################################

# Maps log level names to numeric values for threshold comparison.
# CALLER: log()
_log_level_num() {
    case "$1" in
        debug) echo 0 ;;
        info)  echo 1 ;;
        warn)  echo 2 ;;
        error) echo 3 ;;
        *)     echo 1 ;;
    esac
}

# Central logging function used by ALL modules (sourced modules call log()
# which resolves to this definition). Writes to both file and stderr.
# Every library module has a stub that's overridden when ralph.sh sources it.
# SIDE EFFECT: Creates log directory if absent. Appends to LOG_FILE.
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
        local log_path="${PROJECT_ROOT}/${LOG_FILE}"
        mkdir -p "$(dirname "$log_path")"
        echo "$entry" >> "$log_path"
        echo "$entry" >&2
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
  --mode MODE          Operating mode: handoff-only (default), handoff-plus-index, or agent-orchestrated
  --dry-run            Print what would happen without executing
  --resume             Resume from saved state
  -h, --help           Show this help message
EOF
}

# WHY: CLI flags must override config file values, so we capture MODE before
# load_config() runs, then apply priority in main().
# CALLER: main()
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
            --mode)
                MODE="$2"
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

# WHY: ralph.conf is a shell file sourced directly, so its variables (RALPH_MODE,
# RALPH_MAX_ITERATIONS, etc.) become globals. This must run AFTER parse_args()
# so CLI flags can take precedence in main().
# CALLER: main()
# SIDE EFFECT: Sets globals from ralph.conf (RALPH_MODE, RALPH_VALIDATION_COMMANDS, etc.)
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

# Ensure state file exists for fresh checkouts before any read_state() calls.
# CALLER: main()
# SIDE EFFECT: Writes bootstrap JSON to STATE_FILE when missing.
ensure_state_file() {
    if [[ -f "$STATE_FILE" ]]; then
        return 0
    fi

    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" <<'EOF'
{
  "current_iteration": 0,
  "last_compaction_iteration": 0,
  "coding_iterations_since_compaction": 0,
  "total_handoff_bytes_since_compaction": 0,
  "last_task_id": null,
  "started_at": null,
  "status": "idle",
  "mode": "handoff-only"
}
EOF
}

# Read a single key from state.json. Returns raw jq output (string, number, etc.).
# CALLER: main loop, run_coding_cycle() (for byte/iteration counters)
read_state() {
    if [[ -f "$STATE_FILE" ]]; then
        jq -r ".$1" "$STATE_FILE"
    else
        log "error" "State file not found: $STATE_FILE"
        return 1
    fi
}

# Update a single key in state.json atomically (temp-file-then-rename).
# WHY: The jq expression auto-coerces value types (number, bool, null, string)
# because state.json stores mixed types and callers pass everything as strings.
# CALLER: main loop (status, iteration, mode), run_coding_cycle() (byte/iteration counters)
# SIDE EFFECT: Rewrites STATE_FILE via atomic rename.
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

# WHY: Modules are sourced after config load so they can read config globals
# (RALPH_CONTEXT_BUDGET_TOKENS, RALPH_COMPACTION_INTERVAL, etc.) at source time.
# Glob-based sourcing means new modules are auto-discovered.
# CALLER: main(), after load_config()
# SIDE EFFECT: Defines all functions from .ralph/lib/*.sh in current shell.
# INVARIANT: log() must be defined before this runs (modules call log() at source time).
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

# WHY: The claude CLI's --append-system-prompt-file flag requires a file path,
# not inline content. This bridges context.sh's load_skills() (which returns
# a string) to cli-ops.sh's run_coding_iteration() (which needs a file).
# CALLER: run_coding_cycle()
# SIDE EFFECT: Creates a temp file that the caller must clean up.
# Depends on: load_skills() from context.sh
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

# WHY: The legacy compaction cycle (run_compaction_cycle below) uses a different
# prompt than the knowledge indexer. This builds the memory-agent prompt from
# the template plus handoff data. In handoff-plus-index mode, the knowledge
# indexer uses build_indexer_prompt() in compaction.sh instead.
# CALLER: run_compaction_cycle()
# Depends on: .ralph/templates/memory-prompt.md (optional), task metadata for
#             Context7 library documentation queries
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

    # Inject library documentation request when task needs external API docs
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
# Template protection — detect and restore agent-overwritten templates
###############################################################################

# Verify templates match their git-committed versions.
# Returns 0 if all clean, 1 if any were modified.
# With --restore flag, auto-restores modified templates from git.
# WHY: Agents run with --dangerously-skip-permissions and can write anywhere.
# Rather than chmod-locking (which leaves files stuck at 444 on hard crashes),
# we detect overwrites after the run and restore from git.
# CALLER: main() end, or manual invocation.
verify_templates() {
    local restore="${1:-}"
    local templates_dir="${RALPH_DIR}/templates"
    local dirty=0

    if ! git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        log "debug" "Not a git repo; skipping template verification"
        return 0
    fi

    for tmpl in "$templates_dir"/*.md; do
        [[ -f "$tmpl" ]] || continue
        local rel_path
        rel_path="${tmpl#$PROJECT_ROOT/}"
        if ! git -C "$PROJECT_ROOT" diff --quiet -- "$rel_path" 2>/dev/null; then
            log "warn" "Template modified during run: $rel_path"
            dirty=1
            if [[ "$restore" == "--restore" ]]; then
                git -C "$PROJECT_ROOT" checkout -- "$rel_path" 2>/dev/null || true
                log "info" "Restored template: $rel_path"
            fi
        fi
    done

    return "$dirty"
}

###############################################################################
# Helper: run a complete compaction cycle (legacy, used in handoff-only mode)
###############################################################################

# WHY: This is the LEGACY compaction path, kept for backward compatibility.
# In handoff-plus-index mode, run_knowledge_indexer() (compaction.sh) is used
# instead. This function invokes Claude as a memory agent to produce compacted
# context JSON, which was the pre-knowledge-index approach.
# CALLER: Not actively called in current flow; kept for test compatibility.
# SIDE EFFECT: Writes .ralph/context/compacted-latest.json and compaction-history/
# Depends on: build_compaction_input(), run_memory_iteration(), parse_handoff_output(),
#             update_compaction_state(), extract_response_metadata() from cli-ops.sh/compaction.sh
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

    # Save compacted context (both "latest" pointer and timestamped archive)
    mkdir -p "${RALPH_DIR}/context/compaction-history"
    local iter
    iter="$(read_state "current_iteration")"
    echo "$compacted_json" | jq . > "${RALPH_DIR}/context/compacted-latest.json"
    echo "$compacted_json" | jq . > "${RALPH_DIR}/context/compaction-history/compacted-iter-${iter}.json"
    log "info" "Saved compacted context"

    # Reset compaction counters so trigger doesn't fire immediately next iteration
    update_compaction_state "$STATE_FILE"

    local metadata
    metadata="$(extract_response_metadata "$raw_response")"
    log "info" "Memory iteration metadata: $metadata"

    log "info" "--- Compaction cycle end ---"
}

###############################################################################
# Helper: run agent-orchestrated coding cycle (context agent → coding → knowledge)
###############################################################################

# WHY: In agent-orchestrated mode, the context agent (an LLM) assembles the prompt
# instead of bash. This function wraps the 3-phase flow:
#   Phase 1: Context agent prepares the prompt (writes prepared-prompt.md)
#   Phase 2: Coding agent executes with the prepared prompt
#   Phase 3 (knowledge org) runs post-validation in the main loop, not here.
#
# CALLER: main loop (agent-orchestrated mode only)
# SIDE EFFECT: Creates handoff file, writes prepared-prompt.md, deletes failure
#              context on success, updates compaction counters.
# Returns: 0 + handoff_file path on stdout, or 1 on failure
#          On certain failures, writes DIRECTIVE:<action> to stderr for the caller.
# Depends on: agents.sh (run_context_prep, read_prepared_prompt, handle_prep_directives),
#             cli-ops.sh (run_coding_iteration, parse_handoff_output, save_handoff,
#             extract_response_metadata), context.sh (prepare_skills_file, estimate_tokens)
run_agent_coding_cycle() {
    local task_json="$1"
    local current_iteration="$2"
    local task_id
    task_id="$(echo "$task_json" | jq -r '.id // "unknown"')"

    # --- Phase 1: Context Preparation ---
    log "info" "Phase 1: Context preparation for $task_id"
    local prep_directive
    if ! prep_directive="$(run_context_prep "$task_json" "$current_iteration" "$MODE")"; then
        log "error" "Context preparation failed for $task_id"
        return 1
    fi

    local prep_action
    prep_action="$(handle_prep_directives "$prep_directive")"

    case "$prep_action" in
        proceed)
            ;; # Normal flow — continue to coding
        skip)
            log "warn" "Context agent recommends skipping task $task_id"
            echo "DIRECTIVE:skip" >&2
            return 1
            ;;
        request_human_review)
            log "warn" "Context agent requests human review for $task_id"
            echo "DIRECTIVE:request_human_review" >&2
            return 1
            ;;
        research)
            log "info" "Context agent requests research before coding $task_id"
            echo "DIRECTIVE:research" >&2
            return 1
            ;;
    esac

    # --- Phase 2: Coding ---
    log "info" "Phase 2: Coding iteration for $task_id"
    local prompt
    if ! prompt="$(read_prepared_prompt)"; then
        log "error" "Failed to read prepared prompt for $task_id"
        return 1
    fi

    local skills_file
    skills_file="$(prepare_skills_file "$task_json")"

    log "info" "Prompt prepared by context agent ($(estimate_tokens "$prompt") estimated tokens)"

    local raw_response
    if ! raw_response="$(run_coding_iteration "$prompt" "$task_json" "$skills_file")"; then
        log "error" "Coding iteration failed for $task_id"
        [[ -n "$skills_file" && -f "$skills_file" ]] && rm -f "$skills_file"
        return 1
    fi

    [[ -n "$skills_file" && -f "$skills_file" ]] && rm -f "$skills_file"

    local handoff_json
    if ! handoff_json="$(parse_handoff_output "$raw_response")"; then
        log "error" "Failed to parse handoff output for $task_id"
        return 1
    fi

    # Delete consumed failure context on successful parse
    local failure_ctx_file="${RALPH_DIR}/context/failure-context.md"
    if [[ -f "$failure_ctx_file" ]]; then
        rm -f "$failure_ctx_file"
    fi

    local handoff_file
    handoff_file="$(save_handoff "$handoff_json" "$current_iteration")"

    # Update compaction trigger counters
    local handoff_bytes
    handoff_bytes="$(echo "$handoff_json" | jq -c . | wc -c | tr -d ' ')"
    local prev_bytes
    prev_bytes="$(read_state "total_handoff_bytes_since_compaction")"
    write_state "total_handoff_bytes_since_compaction" "$(( prev_bytes + handoff_bytes ))"

    local prev_iters
    prev_iters="$(read_state "coding_iterations_since_compaction")"
    write_state "coding_iterations_since_compaction" "$(( prev_iters + 1 ))"

    local metadata
    metadata="$(extract_response_metadata "$raw_response")"
    log "info" "Coding iteration metadata: $metadata"

    # Check for coding agent signals
    local human_review_needed
    human_review_needed="$(echo "$handoff_json" | jq -r '.request_human_review.needed // false')"
    if [[ "$human_review_needed" == "true" ]]; then
        local review_reason
        review_reason="$(echo "$handoff_json" | jq -r '.request_human_review.reason // "no reason given"')"
        log "warn" "Coding agent requests human review: $review_reason"
        if declare -f emit_event >/dev/null 2>&1; then
            emit_event "human_review_requested" "Coding agent requests review" \
                "$(jq -cn --arg reason "$review_reason" '{reason: $reason}')" || true
        fi
    fi

    echo "$handoff_file"
}

###############################################################################
# Helper: run a complete coding iteration cycle (prompt -> CLI -> parse -> save)
###############################################################################

# WHY: Encapsulates the entire prompt-assembly-to-handoff-save pipeline so the
# main loop only needs to handle the outcome (success/failure). This is the
# core of what Ralph does each iteration in handoff-only and handoff-plus-index modes.
# CALLER: main loop step 4 (non-agent-orchestrated modes)
# SIDE EFFECT: Creates handoff file, updates compaction counters in state.json,
#              cleans up temp skills file, deletes failure context file on success.
# Returns: 0 + handoff_file path on stdout, or 1 on failure
# Depends on: prepare_skills_file() [context.sh],
#             build_coding_prompt_v2() or build_coding_prompt() [context.sh],
#             truncate_to_budget(), estimate_tokens() [context.sh],
#             run_coding_iteration(), parse_handoff_output(), save_handoff(),
#             extract_response_metadata() [cli-ops.sh]
#   v1 fallback only: format_compacted_context(), get_prev_handoff_summary(),
#             get_earlier_l1_summaries() [context.sh]
run_coding_cycle() {
    local task_json="$1"
    local current_iteration="$2"
    local task_id
    task_id="$(echo "$task_json" | jq -r '.id // "unknown"')"

    # --- Assemble context components ---
    local skills_file prompt

    skills_file="$(prepare_skills_file "$task_json")"

    # Failure context from a previous failed validation — consumed once.
    # Deletion deferred until after successful handoff parse (fixes C3: prevents
    # loss of retry guidance if cycle fails mid-flight).
    local failure_context=""
    local failure_ctx_file="${RALPH_DIR}/context/failure-context.md"
    if [[ -f "$failure_ctx_file" ]]; then
        failure_context="$(cat "$failure_ctx_file")"
        log "info" "Injecting failure context from previous attempt"
    fi

    local skills_content=""
    if [[ -n "$skills_file" && -f "$skills_file" ]]; then
        skills_content="$(cat "$skills_file")"
    fi

    # First-iteration bootstrap: onboarding context for the very first coding
    # pass when no prior handoffs exist. Passed to v2 builder as $5 so it gets
    # injected into ## Previous Handoff (fixes C1: no longer silently discarded).
    local first_iteration_context=""
    if [[ "$current_iteration" -eq 1 && -f "${RALPH_DIR}/templates/first-iteration.md" ]]; then
        first_iteration_context="$(cat "${RALPH_DIR}/templates/first-iteration.md")"
    fi

    # --- Build prompt ---
    # CRITICAL: Prefer v2 (mode-aware, 7-section) over v1 (legacy).
    # The declare -f guard enables graceful degradation if context.sh is an
    # older version that only has build_coding_prompt().
    if declare -f build_coding_prompt_v2 >/dev/null 2>&1; then
        prompt="$(build_coding_prompt_v2 "$task_json" "$MODE" "$skills_content" "$failure_context" "$first_iteration_context")"
    else
        # Legacy v1 path: assemble v1-only context components
        local compacted_context="" prev_handoff="" earlier_l1=""
        if [[ -f "${RALPH_DIR}/context/compacted-latest.json" ]]; then
            compacted_context="$(format_compacted_context "${RALPH_DIR}/context/compacted-latest.json")"
        fi
        prev_handoff="$(get_prev_handoff_summary "${RALPH_DIR}/handoffs")"
        earlier_l1="$(get_earlier_l1_summaries "${RALPH_DIR}/handoffs")"
        if [[ -n "$first_iteration_context" ]]; then
            compacted_context="${first_iteration_context}"$'\n\n'"${compacted_context}"
        fi
        prompt="$(build_coding_prompt "$task_json" "$compacted_context" "$prev_handoff" "$skills_content" "$failure_context" "$earlier_l1")"
    fi

    # Section-aware truncation: trims lowest-priority sections first to fit
    # within mode-appropriate budget. handoff-plus-index gets a larger budget
    # (RALPH_CONTEXT_BUDGET_TOKENS_HPI) because it inlines the full knowledge index.
    local budget
    budget="$(get_budget_for_mode "$MODE")"
    prompt="$(truncate_to_budget "$prompt" "$budget")"

    log "info" "Prompt assembled ($(estimate_tokens "$prompt") estimated tokens)"

    # --- Invoke Claude CLI ---
    local raw_response
    if ! raw_response="$(run_coding_iteration "$prompt" "$task_json" "$skills_file")"; then
        log "error" "Coding iteration failed for $task_id"
        [[ -n "$skills_file" && -f "$skills_file" ]] && rm -f "$skills_file"
        return 1
    fi

    [[ -n "$skills_file" && -f "$skills_file" ]] && rm -f "$skills_file"

    # --- Parse and save handoff ---
    # Double-parse: Claude's response envelope has .result as a JSON string
    # (see cli-ops.sh parse_handoff_output for details).
    local handoff_json
    if ! handoff_json="$(parse_handoff_output "$raw_response")"; then
        log "error" "Failed to parse handoff output for $task_id"
        return 1
    fi

    # Handoff parsed successfully — now safe to delete consumed failure context
    # (fixes C3: deferred deletion prevents loss on mid-cycle failures).
    if [[ -f "$failure_ctx_file" ]]; then
        rm -f "$failure_ctx_file"
    fi

    local handoff_file
    handoff_file="$(save_handoff "$handoff_json" "$current_iteration")"

    # --- Update compaction trigger counters ---
    # These accumulate between compaction runs; check_compaction_trigger()
    # in compaction.sh reads them to decide whether to fire.
    # Use compact JSON byte count for accurate threshold comparison (fixes M2).
    local handoff_bytes
    handoff_bytes="$(echo "$handoff_json" | jq -c . | wc -c | tr -d ' ')"
    local prev_bytes
    prev_bytes="$(read_state "total_handoff_bytes_since_compaction")"
    write_state "total_handoff_bytes_since_compaction" "$(( prev_bytes + handoff_bytes ))"

    local prev_iters
    prev_iters="$(read_state "coding_iterations_since_compaction")"
    write_state "coding_iterations_since_compaction" "$(( prev_iters + 1 ))"

    local metadata
    metadata="$(extract_response_metadata "$raw_response")"
    log "info" "Coding iteration metadata: $metadata"

    # Return handoff file path via stdout (caller captures it)
    echo "$handoff_file"
}

###############################################################################
# Helper: increment retry count for a task in the plan
###############################################################################

# WHY: Retry tracking lives in plan.json alongside the task, not in state.json,
# because retries are per-task (a task may be retried while others succeed).
# CALLER: main loop on coding cycle failure or validation failure
# SIDE EFFECT: Mutates plan.json via temp-file-then-rename.
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

# WHY: Without this, SIGINT during a claude CLI call would leave state.json
# with status "running" and the repo in an unknown state. The handler ensures
# state reflects the interruption so --resume can recover.
# INVARIANT: Must set SHUTTING_DOWN=true before any other work to prevent
# reentrant calls (signal can arrive during log/write_state).
# SIDE EFFECT: Sets state status to "interrupted", emits telemetry event, exits 130.
shutdown_handler() {
    # Reentrant guard — signal can arrive during cleanup
    if [[ "$SHUTTING_DOWN" == "true" ]]; then
        return
    fi
    SHUTTING_DOWN=true
    log "warn" "Received shutdown signal, saving state and exiting"
    # Guard emit_event with declare -f: telemetry.sh may not be sourced yet
    # if signal arrives during startup
    if declare -f emit_event >/dev/null 2>&1; then
        emit_event "orchestrator_end" "Shutdown signal received" '{"reason":"signal"}' || true
    fi
    write_state "status" "interrupted"
    log "info" "State saved. Exiting gracefully."
    exit 130
}

trap shutdown_handler SIGINT SIGTERM

###############################################################################
# Main loop
###############################################################################

# Orchestrator entry point. Parses args, loads config, sources modules, then
# iterates through plan.json tasks until complete, max iterations, or signal.
#
# CONTROL FLOW OVERVIEW:
#   1. parse_args + load_config + resolve MODE priority
#   2. source_libs (all .ralph/lib/*.sh)
#   3. Initialize telemetry + progress log + clean git state
#   4. Loop: for each iteration until plan complete or max reached:
#      a. Check operator commands (pause/resume/skip/note)
#      b. Get next pending task (respects depends_on)
#      c. [handoff-plus-index only] Check compaction triggers
#      d. Create git checkpoint
#      e. Run coding cycle (prompt -> CLI -> parse -> save)
#      f. Run validation gate
#      g. Commit or rollback based on validation result
#      h. Apply plan amendments from handoff
#      i. [agent-orchestrated only] Context post + agent passes
#      j. Rate-limit delay
#
# MODE-SENSITIVE BRANCHING:
#   - Step c (compaction): handoff-plus-index only
#   - Step e (coding cycle): agent-orchestrated uses run_agent_coding_cycle()
#     (context agent → coding agent); other modes use run_coding_cycle()
#     (bash prompt assembly → coding agent)
#   - Step i (post-iteration): agent-orchestrated runs context post (knowledge
#     organization) and optional agent passes (code review, etc.)
#   - build_coding_prompt_v2() internally varies sections 3-6 by mode (non-agent modes)
main() {
    parse_args "$@"
    # Save CLI mode before load_config potentially sets RALPH_MODE
    local cli_mode="$MODE"
    load_config
    # INVARIANT: CLI --mode > RALPH_MODE from config > default "handoff-only"
    if [[ -n "$cli_mode" ]]; then
        MODE="$cli_mode"
    elif [[ -n "${RALPH_MODE:-}" ]]; then
        MODE="$RALPH_MODE"
    else
        MODE="handoff-only"
    fi

    cd "$PROJECT_ROOT"

    local mcp_transport
    mcp_transport="$(detect_mcp_transport)"
    log "info" "Ralph Deluxe starting (dry_run=$DRY_RUN, resume=$RESUME, mode=$MODE, mcp_transport=$mcp_transport)"

    local remaining
    remaining="$(count_remaining_tasks "$PLAN_FILE" 2>/dev/null || echo "?")"
    log "info" "Plan: $PLAN_FILE ($remaining tasks remaining)"

    ensure_state_file

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

    # Persist mode to state so dashboard and resume can read it
    write_state "mode" "$MODE"

    # Source modules AFTER config so they pick up config globals at source time
    source_libs

    # --- Initialize subsystems ---
    # All guarded with declare -f so startup doesn't fail if a module is missing.
    # This enables partial-module testing and graceful degradation.
    if declare -f init_control_file >/dev/null 2>&1; then
        init_control_file
    fi
    if declare -f init_progress_log >/dev/null 2>&1; then
        init_progress_log
    fi
    if declare -f emit_event >/dev/null 2>&1; then
        emit_event "orchestrator_start" "Ralph Deluxe starting" \
            "$(jq -cn --arg mode "$MODE" --argjson dry_run "$DRY_RUN" --argjson resume "$RESUME" \
            '{mode: $mode, dry_run: $dry_run, resume: $resume}')"
    fi

    # Ensure runtime directories exist before main loop.
    # WHY: agent-orchestrated mode redirects stderr to context/.cycle-stderr on line 861;
    # compaction writes to context/compaction-history/; handoffs/ and logs/validation/
    # are created by their respective modules but must exist before first write.
    mkdir -p "${RALPH_DIR}/context" "${RALPH_DIR}/handoffs" "${RALPH_DIR}/logs/validation"

    # INVARIANT: Git working tree must be clean before first checkpoint.
    # Without this, the first rollback would discard pre-existing uncommitted work.
    if [[ "$DRY_RUN" == "false" ]]; then
        ensure_clean_state
    fi

    log "info" "Starting main loop (max_iterations=$MAX_ITERATIONS)"

    while (( current_iteration < MAX_ITERATIONS )); do
        # Cooperative shutdown: check flag set by signal handler
        if [[ "$SHUTTING_DOWN" == "true" ]]; then
            break
        fi

        # Process operator commands BEFORE task selection so pause/skip
        # take effect before the next iteration starts
        if declare -f check_and_handle_commands >/dev/null 2>&1; then
            check_and_handle_commands
        fi

        if is_plan_complete "$PLAN_FILE"; then
            log "info" "All tasks complete. Exiting."
            write_state "status" "complete"
            break
        fi

        local task_json
        task_json="$(get_next_task "$PLAN_FILE")"

        # Empty/null task_json means all pending tasks have unmet dependencies.
        # This is distinct from "plan complete" (all done/skipped).
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

        if declare -f emit_event >/dev/null 2>&1; then
            emit_event "iteration_start" "Starting iteration $current_iteration" \
                "$(jq -cn --arg task_id "$task_id" --arg title "$task_title" --argjson iter "$current_iteration" \
                '{iteration: $iter, task_id: $task_id, task_title: $title}')"
        fi

        # === DRY RUN MODE ===
        # Exercises the full pipeline with mock CLI responses to validate
        # orchestrator logic without spending API credits.
        if [[ "$DRY_RUN" == "true" ]]; then
            log "info" "[DRY RUN] Processing task $task_id (mode=$MODE)"

            # MODE BRANCH: Test compaction triggers even in dry-run (handoff-plus-index only)
            if [[ "$MODE" == "handoff-plus-index" ]]; then
                if check_compaction_trigger "$STATE_FILE" "$task_json" 2>/dev/null; then
                    log "info" "[DRY RUN] Knowledge indexing would be triggered"
                    run_knowledge_indexer "$task_json" || true
                fi
            fi

            set_task_status "$PLAN_FILE" "$task_id" "in_progress"
            local handoff_file
            if [[ "$MODE" == "agent-orchestrated" ]] && declare -f run_agent_coding_cycle >/dev/null 2>&1; then
                handoff_file="$(run_agent_coding_cycle "$task_json" "$current_iteration")" || true
            else
                handoff_file="$(run_coding_cycle "$task_json" "$current_iteration")" || true
            fi
            set_task_status "$PLAN_FILE" "$task_id" "done"
            if declare -f append_progress_entry >/dev/null 2>&1; then
                append_progress_entry "$handoff_file" "$current_iteration" "$task_id" || {
                    log "warn" "Progress log update failed, continuing"
                }
            fi
            continue
        fi

        # === REAL MODE ===

        # Step 1: Pre-task context/indexing (mode-dependent)
        #
        # MODE BRANCHES:
        # - handoff-plus-index: trigger-based knowledge indexer (compaction.sh)
        # - agent-orchestrated: context agent handles this in run_agent_coding_cycle()
        # - handoff-only: no pre-task processing
        if [[ "$MODE" == "handoff-plus-index" ]]; then
            if check_compaction_trigger "$STATE_FILE" "$task_json"; then
                log "info" "Knowledge indexing triggered"
                run_knowledge_indexer "$task_json" || {
                    log "warn" "Knowledge indexing failed, continuing"
                }
            fi
        fi
        # agent-orchestrated mode: no pre-task compaction — the context agent
        # runs inside run_agent_coding_cycle() and manages knowledge autonomously.

        # Step 2: Mark task as in-progress
        set_task_status "$PLAN_FILE" "$task_id" "in_progress"

        # Step 3: Create git checkpoint (SHA for potential rollback)
        # INVARIANT: Every coding cycle is bracketed by checkpoint/commit-or-rollback.
        # This guarantees no half-applied changes persist between iterations.
        local checkpoint
        checkpoint="$(create_checkpoint)"
        log "info" "Checkpoint: ${checkpoint:0:8}"

        # Step 4: Run the coding cycle
        # MODE BRANCH: agent-orchestrated uses the 3-phase agent cycle;
        # other modes use the bash-assembled prompt cycle.
        local handoff_file=""
        local coding_cycle_fn="run_coding_cycle"
        if [[ "$MODE" == "agent-orchestrated" ]] && declare -f run_agent_coding_cycle >/dev/null 2>&1; then
            coding_cycle_fn="run_agent_coding_cycle"
        fi

        if ! handoff_file="$($coding_cycle_fn "$task_json" "$current_iteration" 2>"${RALPH_DIR}/context/.cycle-stderr")"; then
            log "error" "Coding cycle failed for $task_id"

            # In agent-orchestrated mode, check if the context agent issued a directive
            # (skip, human review, research) — these are NOT coding failures.
            local cycle_stderr=""
            if [[ -f "${RALPH_DIR}/context/.cycle-stderr" ]]; then
                cycle_stderr="$(cat "${RALPH_DIR}/context/.cycle-stderr")"
                rm -f "${RALPH_DIR}/context/.cycle-stderr"
            fi

            if [[ "$cycle_stderr" == *"DIRECTIVE:skip"* ]]; then
                log "info" "Context agent directive: skip task $task_id"
                set_task_status "$PLAN_FILE" "$task_id" "skipped"
                if declare -f emit_event >/dev/null 2>&1; then
                    emit_event "iteration_end" "Task $task_id skipped by context agent" \
                        "$(jq -cn --arg task_id "$task_id" --argjson iter "$current_iteration" --arg result "skipped" \
                        '{iteration: $iter, task_id: $task_id, result: $result}')"
                fi
                log "info" "=== End iteration $current_iteration (skipped) ==="
                continue
            elif [[ "$cycle_stderr" == *"DIRECTIVE:request_human_review"* ]]; then
                log "warn" "Context agent directive: human review needed for $task_id"
                set_task_status "$PLAN_FILE" "$task_id" "pending"
                write_state "status" "paused"
                if declare -f emit_event >/dev/null 2>&1; then
                    emit_event "pause" "Paused for human review (context agent recommendation)" \
                        "$(jq -cn --arg task_id "$task_id" '{task_id: $task_id, reason: "context_agent_review"}')"
                fi
                log "info" "=== End iteration $current_iteration (paused for review) ==="
                break
            elif [[ "$cycle_stderr" == *"DIRECTIVE:research"* ]]; then
                log "info" "Context agent directive: research needed for $task_id"
                # Research directive: task stays pending, loop continues to next iteration
                # where the context agent will have another chance to prepare context.
                set_task_status "$PLAN_FILE" "$task_id" "pending"
                if declare -f emit_event >/dev/null 2>&1; then
                    emit_event "iteration_end" "Research requested for $task_id" \
                        "$(jq -cn --arg task_id "$task_id" --argjson iter "$current_iteration" --arg result "research_requested" \
                        '{iteration: $iter, task_id: $task_id, result: $result}')"
                fi
                log "info" "=== End iteration $current_iteration (research requested) ==="
                continue
            fi

            rollback_to_checkpoint "$checkpoint"
            set_task_status "$PLAN_FILE" "$task_id" "pending"
            increment_retry_count "$PLAN_FILE" "$task_id"

            local retry_count max_retries
            retry_count="$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .retry_count // 0' "$PLAN_FILE")"
            max_retries="$(echo "$task_json" | jq -r '.max_retries // 2')"
            if (( retry_count >= max_retries )); then
                log "error" "Task $task_id exceeded max retries ($max_retries)"
                set_task_status "$PLAN_FILE" "$task_id" "failed"
            fi
            if declare -f emit_event >/dev/null 2>&1; then
                emit_event "iteration_end" "Coding cycle failed for $task_id" \
                    "$(jq -cn --arg task_id "$task_id" --argjson iter "$current_iteration" --arg result "coding_failed" \
                    '{iteration: $iter, task_id: $task_id, result: $result}')"
            fi
            log "info" "=== End iteration $current_iteration (coding failed) ==="
            continue
        fi

        # Clean up stderr capture file on success
        rm -f "${RALPH_DIR}/context/.cycle-stderr"

        # Step 5: Run validation gate
        # Branch point: pass path commits + advances plan; fail path rolls back and
        # feeds retry context into the next attempt.
        # Validation strategy (strict/lenient/tests_only) is set in ralph.conf.
        # Results written to .ralph/logs/validation/iter-N.json for failure context.
        local validation_result="failed"
        if run_validation "$current_iteration"; then
            validation_result="passed"
            log "info" "Validation PASSED for iteration $current_iteration"
            if declare -f emit_event >/dev/null 2>&1; then
                emit_event "validation_pass" "Validation passed for iteration $current_iteration" \
                    "$(jq -cn --arg task_id "$task_id" --argjson iter "$current_iteration" \
                    '{iteration: $iter, task_id: $task_id}')"
            fi

            # Step 6a: Commit successful iteration
            commit_iteration "$current_iteration" "$task_id" "passed validation"
            set_task_status "$PLAN_FILE" "$task_id" "done"

            # Step 6b: Append progress log entry
            if declare -f append_progress_entry >/dev/null 2>&1; then
                append_progress_entry "$handoff_file" "$current_iteration" "$task_id" || {
                    log "warn" "Progress log update failed, continuing"
                }
            fi

            # Step 7: Apply plan amendments from handoff (if any)
            if [[ -n "$handoff_file" && -f "$handoff_file" ]]; then
                apply_amendments "$PLAN_FILE" "$handoff_file" "$task_id" || {
                    log "warn" "Amendment application had issues, continuing"
                }
            fi

            log "info" "Remaining tasks: $(count_remaining_tasks "$PLAN_FILE")"
            if declare -f emit_event >/dev/null 2>&1; then
                emit_event "iteration_end" "Iteration $current_iteration completed successfully" \
                    "$(jq -cn --arg task_id "$task_id" --argjson iter "$current_iteration" --arg result "success" \
                    '{iteration: $iter, task_id: $task_id, result: $result}')"
            fi
        else
            log "warn" "Validation FAILED for iteration $current_iteration"
            if declare -f emit_event >/dev/null 2>&1; then
                emit_event "validation_fail" "Validation failed for iteration $current_iteration" \
                    "$(jq -cn --arg task_id "$task_id" --argjson iter "$current_iteration" \
                    '{iteration: $iter, task_id: $task_id}')"
            fi

            rollback_to_checkpoint "$checkpoint"
            increment_retry_count "$PLAN_FILE" "$task_id"

            local retry_count max_retries
            retry_count="$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .retry_count // 0' "$PLAN_FILE")"
            max_retries="$(echo "$task_json" | jq -r '.max_retries // 2')"

            if (( retry_count >= max_retries )); then
                log "error" "Task $task_id exceeded max retries ($max_retries), marking failed"
                set_task_status "$PLAN_FILE" "$task_id" "failed"
            else
                log "info" "Will retry task $task_id (attempt ${retry_count}/$max_retries)"
                set_task_status "$PLAN_FILE" "$task_id" "pending"
            fi

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
            if declare -f emit_event >/dev/null 2>&1; then
                emit_event "iteration_end" "Iteration $current_iteration ended (validation failed)" \
                    "$(jq -cn --arg task_id "$task_id" --argjson iter "$current_iteration" --arg result "validation_failed" \
                    '{iteration: $iter, task_id: $task_id, result: $result}')"
            fi
        fi

        # Step 8: Post-iteration agent passes (agent-orchestrated mode only)
        # Runs AFTER validation regardless of pass/fail — the context agent needs
        # to see failures too for pattern detection and knowledge organization.
        if [[ "$MODE" == "agent-orchestrated" ]] && [[ -n "$handoff_file" && -f "$handoff_file" ]]; then
            # Phase 3: Knowledge organization
            if declare -f run_context_post >/dev/null 2>&1; then
                local post_directive
                post_directive="$(run_context_post "$handoff_file" "$current_iteration" "$task_id" "$validation_result")" || {
                    log "warn" "Context post-processing failed, continuing"
                }
                if [[ -n "$post_directive" ]] && declare -f handle_post_directives >/dev/null 2>&1; then
                    local post_action
                    post_action="$(handle_post_directives "$post_directive")"
                    # Post-processing directives are advisory — logged but the orchestrator
                    # does not break the loop on them. They inform the NEXT iteration's
                    # context prep pass via the knowledge index and event stream.
                    if [[ "$post_action" == "request_human_review" ]]; then
                        log "warn" "Context post recommends human review — will be visible to next context prep"
                    fi
                fi
            fi

            # Phase 4: Optional agent passes (code review, documentation, etc.)
            if [[ "${RALPH_AGENT_PASSES_ENABLED:-true}" == "true" ]] && declare -f run_agent_passes >/dev/null 2>&1; then
                run_agent_passes "$handoff_file" "$current_iteration" "$task_id" "$validation_result" || {
                    log "warn" "Agent passes had issues, continuing"
                }
            fi
        fi

        log "info" "=== End iteration $current_iteration ==="

        # Rate limit protection: configurable delay prevents hitting API rate limits
        # when iterations complete quickly (e.g., small tasks or dry-run-like passes).
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

    if declare -f emit_event >/dev/null 2>&1; then
        local final_status
        final_status="$(read_state "status" 2>/dev/null || echo "unknown")"
        emit_event "orchestrator_end" "Ralph Deluxe finished" \
            "$(jq -cn --arg status "$final_status" --argjson iter "$current_iteration" \
            '{status: $status, iterations_completed: $iter}')" || true
    fi

    # Verify templates weren't modified during the run; restore if needed
    verify_templates "--restore" || log "warn" "Templates were modified during run and have been restored"

    log "info" "Ralph Deluxe finished ($(count_remaining_tasks "$PLAN_FILE" 2>/dev/null || echo "?") tasks remaining)"
}

# Run main unless being sourced (for testing).
# This guard allows bats tests to `source ralph.sh` and call individual
# functions without triggering the main loop.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
