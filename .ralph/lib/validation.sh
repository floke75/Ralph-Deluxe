#!/usr/bin/env bash
set -euo pipefail

# Validation gate module for Ralph Deluxe orchestrator.
# Provides configurable validation checks with strategy-based evaluation.

# Stub log function for standalone sourcing (overridden when ralph.sh sources this)
if ! declare -f log &>/dev/null; then
    log() { echo "[validation] $*" >&2; }
fi

# Classify a command as "test" or "lint" based on its name.
# Args: $1 = command string
# Stdout: "test" or "lint"
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

# Run all configured validation checks and write results JSON.
# Args: $1 = iteration number
# Globals: RALPH_VALIDATION_COMMANDS (array), RALPH_VALIDATION_STRATEGY
# Writes: .ralph/logs/validation/iter-${iteration}.json
# Returns: 0 if validation passes, 1 if fails
run_validation() {
    local iteration="$1"
    local strategy="${RALPH_VALIDATION_STRATEGY:-strict}"
    local validation_dir=".ralph/logs/validation"
    local result_file="${validation_dir}/iter-${iteration}.json"

    mkdir -p "$validation_dir"

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

    # Build the full result object
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

# Evaluate check results against a validation strategy.
# Args: $1 = checks JSON array, $2 = strategy (strict|lenient|tests_only)
# Stdout: "true" or "false"
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

# Generate a failure context summary for the next iteration prompt.
# Args: $1 = path to validation result JSON file
# Stdout: formatted failure context string
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

    local context="## Validation Failures"
    local i cmd output truncated

    for (( i=0; i<num_failed; i++ )); do
        cmd="$(echo "$failed_checks" | jq -r ".[$i].command")"
        output="$(echo "$failed_checks" | jq -r ".[$i].output")"

        # Truncate output to 500 chars
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
