#!/usr/bin/env bash
set -euo pipefail

# validation.sh — Post-iteration validation gate for go/no-go decisions
#
# ROLE IN LOOP CONTROL:
#   Validation is the policy checkpoint between "code changed" and "state is
#   accepted." After each iteration, this module executes configured checks and
#   emits a pass/fail signal consumed by ralph.sh to decide whether work can
#   move forward (go: commit path) or must be retried/rolled back (no-go path).
#   In other words, this file is the boundary where command outcomes become
#   orchestration decisions.
#
# PURPOSE: Runs configured validation commands after each coding iteration to
# decide whether to commit or rollback. Supports three strategies that trade off
# strictness for forward progress. Produces structured results for failure context
# injection into the retry prompt.
#
# DEPENDENCIES:
#   Called by: ralph.sh main loop step 5 (run_validation)
#   Depends on: jq, log() from ralph.sh, eval (for command execution)
#   Globals read: RALPH_VALIDATION_COMMANDS (array of shell commands),
#                 RALPH_VALIDATION_STRATEGY ("strict"|"lenient"|"tests_only")
#   Files written: .ralph/logs/validation/iter-N.json (per-iteration results)
#   State interactions: ralph.sh reads return code from run_validation() to
#     drive commit/retry flow, and may call generate_failure_context() to build
#     .ralph/context/failure-context.md for the next prompt.
#
# DATA FLOW:
#   run_validation(iteration)
#     → runs each command in RALPH_VALIDATION_COMMANDS
#     → classify_command() tags each as "test" or "lint"
#     → evaluate_results() applies strategy to decide pass/fail
#     → writes .ralph/logs/validation/iter-N.json
#     → returns 0 (pass) or 1 (fail)
#   On failure:
#     → ralph.sh calls generate_failure_context(validation_file)
#     → output saved to .ralph/context/failure-context.md
#     → injected into ## Failure Context section of next retry prompt
#
# STRATEGIES:
#   strict    — ALL checks must pass (default)
#   lenient   — test commands must pass, lint failures are tolerated
#   tests_only — only test-classified commands evaluated, lint ignored entirely

# Stub log function for standalone sourcing (overridden when ralph.sh sources this)
if ! declare -f log &>/dev/null; then
    log() { echo "[validation] $*" >&2; }
fi

# Tag a command as "test" or "lint" based on known command names.
# This classification drives strategy evaluation: lenient/tests_only modes
# only require test-tagged commands to pass.
# Args: $1 = command string
# Stdout: "test" or "lint"
# NOTE: Unknown commands default to "test" (fail-safe: they block progress).
classify_command() {
    local cmd="$1"
    if [[ "$cmd" =~ (shellcheck|lint|eslint|flake8|pylint|stylelint) ]]; then
        echo "lint"
    elif [[ "$cmd" =~ (bats|test|pytest|jest|cargo\ test|mocha|rspec) ]]; then
        echo "test"
    else
        echo "test"
    fi
}

# Run all configured validation checks and write structured results.
# Command resolution/execution:
#   - Uses RALPH_VALIDATION_COMMANDS exactly as configured (ordered array).
#   - classify_command() assigns each command a "test"/"lint" type used later
#     by strategy evaluation.
#   - eval executes raw command strings so shell syntax (pipes/redirection,
#     compound commands, flags) works as authored.
# Output/status capture:
#   - Captures merged stdout/stderr via `2>&1` into `output`.
#   - Stores numeric `exit_code` and derived boolean `passed` per command.
#   - Persists the full check list plus overall `passed` decision in
#     `.ralph/logs/validation/iter-${iteration}.json`.
# Side effects/state:
#   - Always creates `.ralph/logs/validation/` if missing.
#   - Returns shell status 0/1 as the authoritative go/no-go signal consumed by
#     ralph.sh to continue to commit flow or branch into retry handling.
# Args: $1 = iteration number
# Globals: RALPH_VALIDATION_COMMANDS (array), RALPH_VALIDATION_STRATEGY
# Writes: .ralph/logs/validation/iter-${iteration}.json
# Returns: 0 if validation passes, 1 if fails
# CALLER: ralph.sh main loop step 5
run_validation() {
    local iteration="$1"
    local strategy="${RALPH_VALIDATION_STRATEGY:-strict}"
    local validation_dir=".ralph/logs/validation"
    local result_file="${validation_dir}/iter-${iteration}.json"

    mkdir -p "$validation_dir"

    # Guard: warn if no validation commands are configured (fixes H3).
    # An empty array silently auto-passes validation which can mask real failures.
    if [[ ${#RALPH_VALIDATION_COMMANDS[@]} -eq 0 ]]; then
        log "warn" "No validation commands configured — auto-passing validation"
    fi

    local checks_json="[]"
    local cmd output exit_code cmd_type

    for cmd in "${RALPH_VALIDATION_COMMANDS[@]}"; do
        cmd_type="$(classify_command "$cmd")"
        log "Running validation check: $cmd (type: $cmd_type)"

        output=""
        exit_code=0
        output="$(eval "$cmd" 2>&1)" || exit_code=$?

        local passed="true"
        if [[ "$exit_code" -ne 0 ]]; then
            passed="false"
        fi

        # Append check to JSON array
        checks_json="$(echo "$checks_json" | jq \
            --arg cmd "$cmd" \
            --arg output "$output" \
            --argjson exit_code "$exit_code" \
            --arg passed "$passed" \
            --arg cmd_type "$cmd_type" \
            '. + [{
                "command": $cmd,
                "exit_code": $exit_code,
                "output": $output,
                "passed": ($passed == "true"),
                "type": $cmd_type
            }]')"
    done

    # Apply strategy to determine overall pass/fail
    local overall_passed
    overall_passed="$(evaluate_results "$checks_json" "$strategy")"

    jq -n \
        --argjson iteration "$iteration" \
        --arg strategy "$strategy" \
        --arg passed "$overall_passed" \
        --argjson checks "$checks_json" \
        '{
            "iteration": $iteration,
            "strategy": $strategy,
            "passed": ($passed == "true"),
            "checks": $checks
        }' > "$result_file"

    log "Validation result: passed=$overall_passed (strategy=$strategy)"

    if [[ "$overall_passed" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# Apply validation strategy to check results.
# Args: $1 = checks JSON array, $2 = strategy (strict|lenient|tests_only)
# Stdout: "true" or "false"
# NOTE: lenient and tests_only have identical logic (both ignore lint failures)
# but are kept separate for semantic clarity in config.
evaluate_results() {
    local checks_json="$1"
    local strategy="$2"

    case "$strategy" in
        strict)
            # All checks must pass
            local any_failed
            any_failed="$(echo "$checks_json" | jq '[.[] | select(.passed == false)] | length')"
            if [[ "$any_failed" -eq 0 ]]; then
                echo "true"
            else
                echo "false"
            fi
            ;;
        lenient)
            # Tests must pass, lint failures are OK
            local test_failures
            test_failures="$(echo "$checks_json" | jq '[.[] | select(.type == "test" and .passed == false)] | length')"
            if [[ "$test_failures" -eq 0 ]]; then
                echo "true"
            else
                echo "false"
            fi
            ;;
        tests_only)
            # Only test commands must pass, lint is ignored entirely
            local test_failures
            test_failures="$(echo "$checks_json" | jq '[.[] | select(.type == "test" and .passed == false)] | length')"
            if [[ "$test_failures" -eq 0 ]]; then
                echo "true"
            else
                echo "false"
            fi
            ;;
        *)
            log "Unknown validation strategy: $strategy, defaulting to strict"
            local any_failed
            any_failed="$(echo "$checks_json" | jq '[.[] | select(.passed == false)] | length')"
            if [[ "$any_failed" -eq 0 ]]; then
                echo "true"
            else
                echo "false"
            fi
            ;;
    esac
}

# Generate a failure context summary for the next iteration's retry prompt.
# Failure-context surfacing:
#   - Reads `.ralph/logs/validation/iter-N.json` and filters failed checks.
#   - Emits concise markdown bullets containing failed command + truncated error
#     text so retries focus on actionable breakages.
#   - Truncates each captured output to 500 chars to preserve prompt budget
#     before additional trimming by context.sh utilities.
# Side effects/state:
#   - No file writes here; caller (ralph.sh) persists this output to
#     `.ralph/context/failure-context.md`, which is then injected into the next
#     retry prompt's failure section.
# Args: $1 = path to validation result JSON file (iter-N.json)
# Stdout: markdown formatted failure context for ## Failure Context section
# CALLER: ralph.sh main loop, after validation failure, before saving to
#   .ralph/context/failure-context.md
generate_failure_context() {
    local result_file="$1"

    if [[ ! -f "$result_file" ]]; then
        echo ""
        return 0
    fi

    local failed_checks
    failed_checks="$(jq '[.checks[] | select(.passed == false)]' "$result_file")"

    local num_failed
    num_failed="$(echo "$failed_checks" | jq 'length')"

    if [[ "$num_failed" -eq 0 ]]; then
        echo ""
        return 0
    fi

    # Use ### to avoid conflicting with the parent ## Failure Context header (fixes H4).
    local context="### Validation Failures"
    local i cmd output truncated

    for (( i=0; i<num_failed; i++ )); do
        cmd="$(echo "$failed_checks" | jq -r ".[$i].command")"
        output="$(echo "$failed_checks" | jq -r ".[$i].output")"

        # Truncate output to 500 chars to conserve context budget
        if [[ "${#output}" -gt 500 ]]; then
            truncated="${output:0:500}..."
        else
            truncated="$output"
        fi

        context+=$'\n'"- Check: ${cmd}"
        context+=$'\n'"  Error: ${truncated}"
    done

    echo "$context"
}
