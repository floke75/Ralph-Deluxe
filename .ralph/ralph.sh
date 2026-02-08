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
MODE=""  # handoff-only | handoff-plus-index (set by CLI, config, or default)

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
  --mode MODE          Operating mode: handoff-only (default) or handoff-plus-index
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
# Helper: run a complete coding iteration cycle (prompt -> CLI -> parse -> save)
###############################################################################

# WHY: Encapsulates the entire prompt-assembly-to-handoff-save pipeline so the
# main loop only needs to handle the outcome (success/failure). This is the
# core of what Ralph does each iteration.
# CALLER: main loop step 4
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
    # CRITICAL: Prefer v2 (mode-aware, 8-section) over v1 (legacy).
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
    # within RALPH_CONTEXT_BUDGET_TOKENS. See context.sh for priority order.
    prompt="$(truncate_to_budget "$prompt")"

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
#      i. Rate-limit delay
#
# MODE-SENSITIVE BRANCHING:
#   - Step 1 (compaction check): only runs in handoff-plus-index mode
#   - build_coding_prompt_v2() internally varies sections 3-6 by mode
#   - All other steps are mode-agnostic
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

    log "info" "Ralph Deluxe starting (dry_run=$DRY_RUN, resume=$RESUME, mode=$MODE)"

    local remaining
    remaining="$(count_remaining_tasks "$PLAN_FILE" 2>/dev/null || echo "?")"
    log "info" "Plan: $PLAN_FILE ($remaining tasks remaining)"

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
            handoff_file="$(run_coding_cycle "$task_json" "$current_iteration")" || true
            set_task_status "$PLAN_FILE" "$task_id" "done"
            if declare -f append_progress_entry >/dev/null 2>&1; then
                append_progress_entry "$handoff_file" "$current_iteration" "$task_id" || {
                    log "warn" "Progress log update failed, continuing"
                }
            fi
            continue
        fi

        # === REAL MODE ===

        # Step 1: Knowledge indexing check (handoff-plus-index mode only)
        # Control-flow integration point: this is the only pre-task branch that
        # can inject compaction work before checkpoint+coding; failure is non-fatal
        # so task execution remains forward-progressing.
        # The trigger evaluation (compaction.sh) checks 4 conditions in priority
        # order: task metadata > novelty > bytes > periodic.
        if [[ "$MODE" == "handoff-plus-index" ]]; then
            if check_compaction_trigger "$STATE_FILE" "$task_json"; then
                log "info" "Knowledge indexing triggered"
                # Non-fatal: indexing failure should not block the coding iteration.
                # The coding prompt can still work without updated index.
                run_knowledge_indexer "$task_json" || {
                    log "warn" "Knowledge indexing failed, continuing"
                }
            fi
        fi

        # Step 2: Mark task as in-progress
        set_task_status "$PLAN_FILE" "$task_id" "in_progress"

        # Step 3: Create git checkpoint (SHA for potential rollback)
        # INVARIANT: Every coding cycle is bracketed by checkpoint/commit-or-rollback.
        # This guarantees no half-applied changes persist between iterations.
        local checkpoint
        checkpoint="$(create_checkpoint)"
        log "info" "Checkpoint: ${checkpoint:0:8}"

        # Step 4: Run the coding cycle (prompt -> CLI -> parse -> save)
        local handoff_file=""
        if ! handoff_file="$(run_coding_cycle "$task_json" "$current_iteration")"; then
            log "error" "Coding cycle failed for $task_id"
            rollback_to_checkpoint "$checkpoint"
            # Retry transition: return task to pending before `continue` so the
            # scheduler can pick it again on the next loop pass.
            set_task_status "$PLAN_FILE" "$task_id" "pending"
            increment_retry_count "$PLAN_FILE" "$task_id"

            # Retry gate: re-read count from plan.json AFTER increment to get the
            # current value (fixes L1: stale task_json snapshot caused off-by-one).
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

        # Step 5: Run validation gate
        # Branch point: pass path commits + advances plan; fail path rolls back and
        # feeds retry context into the next attempt.
        # Validation strategy (strict/lenient/tests_only) is set in ralph.conf.
        # Results written to .ralph/logs/validation/iter-N.json for failure context.
        if run_validation "$current_iteration"; then
            log "info" "Validation PASSED for iteration $current_iteration"
            if declare -f emit_event >/dev/null 2>&1; then
                emit_event "validation_pass" "Validation passed for iteration $current_iteration" \
                    "$(jq -cn --arg task_id "$task_id" --argjson iter "$current_iteration" \
                    '{iteration: $iter, task_id: $task_id}')"
            fi

            # Step 6a: Commit successful iteration
            # INVARIANT: Commit happens BEFORE task status change, so a crash
            # between commit and status update results in a committed but
            # still-in-progress task (recoverable on resume).
            commit_iteration "$current_iteration" "$task_id" "passed validation"
            set_task_status "$PLAN_FILE" "$task_id" "done"

            # Step 6b: Append progress log entry
            if declare -f append_progress_entry >/dev/null 2>&1; then
                append_progress_entry "$handoff_file" "$current_iteration" "$task_id" || {
                    log "warn" "Progress log update failed, continuing"
                }
            fi

            # Step 7: Apply plan amendments from handoff (if any)
            # The coding agent can propose adding, modifying, or removing tasks
            # based on what it discovers during implementation. Safety guardrails
            # in plan-ops.sh limit to 3 amendments and protect "done" tasks.
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

            # Step 6b (failure path): Rollback to checkpoint
            # INVARIANT: After rollback, working tree matches pre-iteration state.
            # .ralph/ is excluded from git clean so handoffs and state survive.
            rollback_to_checkpoint "$checkpoint"

            increment_retry_count "$PLAN_FILE" "$task_id"

            # Re-read count from plan.json AFTER increment (fixes L1: stale snapshot).
            local retry_count max_retries
            retry_count="$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .retry_count // 0' "$PLAN_FILE")"
            max_retries="$(echo "$task_json" | jq -r '.max_retries // 2')"

            # Validation-fail retry branch: terminalize when budget is exhausted,
            # otherwise requeue by setting pending.
            if (( retry_count >= max_retries )); then
                log "error" "Task $task_id exceeded max retries ($max_retries), marking failed"
                set_task_status "$PLAN_FILE" "$task_id" "failed"
            else
                log "info" "Will retry task $task_id (attempt ${retry_count}/$max_retries)"
                set_task_status "$PLAN_FILE" "$task_id" "pending"
            fi

            # Save failure context for the retry iteration's prompt.
            # This creates a feedback loop: validation output -> failure-context.md
            # -> consumed by run_coding_cycle() on next attempt -> injected into
            # ## Failure Context section -> LLM sees what went wrong and fixes it.
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

    log "info" "Ralph Deluxe finished ($(count_remaining_tasks "$PLAN_FILE" 2>/dev/null || echo "?") tasks remaining)"
}

# Run main unless being sourced (for testing).
# This guard allows bats tests to `source ralph.sh` and call individual
# functions without triggering the main loop.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
