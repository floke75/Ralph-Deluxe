#!/usr/bin/env bats

# Scope: unit tests for validation strategy evaluation and result persistence helpers.
# Fixture notes: tests run inside TEST_DIR with a minimal .ralph/logs/validation tree
# and a stub log() function before sourcing validation.sh.


setup() {
    # Create a temporary directory for each test
    TEST_DIR="$(mktemp -d)"
    export TEST_DIR

    # Create the .ralph/logs/validation directory structure
    mkdir -p "$TEST_DIR/.ralph/logs/validation"

    # Save original directory and switch to test dir
    ORIG_DIR="$PWD"
    cd "$TEST_DIR"

    # Stub log function
    log() { :; }
    export -f log

    # Source the module under test
    source "$ORIG_DIR/.ralph/lib/validation.sh"
}

teardown() {
    cd "$ORIG_DIR"
    rm -rf "$TEST_DIR"
}

# --- evaluate_results tests ---

@test "strict strategy: all pass -> overall pass" {
    local checks='[
        {"command": "bats tests/", "exit_code": 0, "output": "ok", "passed": true, "type": "test"},
        {"command": "shellcheck script.sh", "exit_code": 0, "output": "ok", "passed": true, "type": "lint"}
    ]'
    run evaluate_results "$checks" "strict"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "true" ]]
}

@test "strict strategy: one lint fail -> overall fail" {
    local checks='[
        {"command": "bats tests/", "exit_code": 0, "output": "ok", "passed": true, "type": "test"},
        {"command": "shellcheck script.sh", "exit_code": 1, "output": "error found", "passed": false, "type": "lint"}
    ]'
    run evaluate_results "$checks" "strict"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "false" ]]
}

@test "strict strategy: one test fail -> overall fail" {
    local checks='[
        {"command": "bats tests/", "exit_code": 1, "output": "test failed", "passed": false, "type": "test"},
        {"command": "shellcheck script.sh", "exit_code": 0, "output": "ok", "passed": true, "type": "lint"}
    ]'
    run evaluate_results "$checks" "strict"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "false" ]]
}

@test "lenient strategy: test pass + lint fail -> overall pass" {
    local checks='[
        {"command": "bats tests/", "exit_code": 0, "output": "ok", "passed": true, "type": "test"},
        {"command": "shellcheck script.sh", "exit_code": 1, "output": "warning", "passed": false, "type": "lint"}
    ]'
    run evaluate_results "$checks" "lenient"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "true" ]]
}

@test "lenient strategy: test fail -> overall fail" {
    local checks='[
        {"command": "bats tests/", "exit_code": 1, "output": "test failed", "passed": false, "type": "test"},
        {"command": "shellcheck script.sh", "exit_code": 0, "output": "ok", "passed": true, "type": "lint"}
    ]'
    run evaluate_results "$checks" "lenient"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "false" ]]
}

@test "tests_only strategy: test pass + lint fail -> overall pass" {
    local checks='[
        {"command": "bats tests/", "exit_code": 0, "output": "ok", "passed": true, "type": "test"},
        {"command": "shellcheck script.sh", "exit_code": 1, "output": "warning", "passed": false, "type": "lint"}
    ]'
    run evaluate_results "$checks" "tests_only"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "true" ]]
}

@test "tests_only strategy: test fail -> overall fail" {
    local checks='[
        {"command": "pytest tests/", "exit_code": 1, "output": "FAILED", "passed": false, "type": "test"},
        {"command": "eslint src/", "exit_code": 1, "output": "errors", "passed": false, "type": "lint"}
    ]'
    run evaluate_results "$checks" "tests_only"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "false" ]]
}

# --- classify_command tests ---

@test "classify_command: bats -> test" {
    run classify_command "bats tests/"
    [[ "$output" == "test" ]]
}

@test "classify_command: shellcheck -> lint" {
    run classify_command "shellcheck script.sh"
    [[ "$output" == "lint" ]]
}

@test "classify_command: pytest -> test" {
    run classify_command "pytest tests/"
    [[ "$output" == "test" ]]
}

@test "classify_command: eslint -> lint" {
    run classify_command "eslint src/"
    [[ "$output" == "lint" ]]
}

@test "classify_command: unknown command -> test (default)" {
    run classify_command "make check"
    [[ "$output" == "test" ]]
}

# --- run_validation tests ---

@test "run_validation writes results JSON with correct structure" {
    # Mock validation commands that succeed
    RALPH_VALIDATION_COMMANDS=("true" "true")
    RALPH_VALIDATION_STRATEGY="strict"

    run_validation 1

    local result_file="$TEST_DIR/.ralph/logs/validation/iter-1.json"
    [[ -f "$result_file" ]]

    # Verify JSON structure
    run jq -e '.iteration' "$result_file"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "1" ]]

    run jq -e '.strategy' "$result_file"
    [[ "$status" -eq 0 ]]
    [[ "$output" == '"strict"' ]]

    run jq -e '.passed' "$result_file"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "true" ]]

    run jq -e '.checks | length' "$result_file"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "2" ]]
}

@test "run_validation returns 0 when all checks pass" {
    RALPH_VALIDATION_COMMANDS=("true" "true")
    RALPH_VALIDATION_STRATEGY="strict"

    run run_validation 1
    [[ "$status" -eq 0 ]]
}

@test "run_validation returns 1 when a check fails (strict)" {
    RALPH_VALIDATION_COMMANDS=("true" "false")
    RALPH_VALIDATION_STRATEGY="strict"

    run run_validation 2
    [[ "$status" -eq 1 ]]

    local result_file="$TEST_DIR/.ralph/logs/validation/iter-2.json"
    run jq -e '.passed' "$result_file"
    [[ "$output" == "false" ]]
}

@test "run_validation captures command output" {
    # Create a command that produces output
    mock_cmd="$TEST_DIR/mock_test.sh"
    cat > "$mock_cmd" <<'SCRIPT'
#!/usr/bin/env bash
echo "test output line 1"
echo "test output line 2"
exit 0
SCRIPT
    chmod +x "$mock_cmd"

    RALPH_VALIDATION_COMMANDS=("$mock_cmd")
    RALPH_VALIDATION_STRATEGY="strict"

    run_validation 3

    local result_file="$TEST_DIR/.ralph/logs/validation/iter-3.json"
    run jq -r '.checks[0].output' "$result_file"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"test output line 1"* ]]
    [[ "$output" == *"test output line 2"* ]]
}

@test "run_validation captures exit code of failed commands" {
    mock_cmd="$TEST_DIR/mock_fail.sh"
    cat > "$mock_cmd" <<'SCRIPT'
#!/usr/bin/env bash
echo "something went wrong"
exit 42
SCRIPT
    chmod +x "$mock_cmd"

    RALPH_VALIDATION_COMMANDS=("$mock_cmd")
    RALPH_VALIDATION_STRATEGY="strict"

    run run_validation 4
    [[ "$status" -eq 1 ]]

    local result_file="$TEST_DIR/.ralph/logs/validation/iter-4.json"
    run jq '.checks[0].exit_code' "$result_file"
    [[ "$output" == "42" ]]

    run jq '.checks[0].passed' "$result_file"
    [[ "$output" == "false" ]]
}

# --- generate_failure_context tests ---

@test "generate_failure_context produces formatted output for failures" {
    local result_file="$TEST_DIR/result.json"
    cat > "$result_file" <<'JSON'
{
    "iteration": 5,
    "strategy": "strict",
    "passed": false,
    "checks": [
        {
            "command": "bats tests/",
            "exit_code": 1,
            "output": "not ok 1 - test failed\n  expected 0, got 1",
            "passed": false,
            "type": "test"
        },
        {
            "command": "shellcheck script.sh",
            "exit_code": 0,
            "output": "ok",
            "passed": true,
            "type": "lint"
        }
    ]
}
JSON

    run generate_failure_context "$result_file"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"## Validation Failures"* ]]
    [[ "$output" == *"- Check: bats tests/"* ]]
    [[ "$output" == *"Error:"* ]]
}

@test "generate_failure_context returns empty string when all checks pass" {
    local result_file="$TEST_DIR/result.json"
    cat > "$result_file" <<'JSON'
{
    "iteration": 1,
    "strategy": "strict",
    "passed": true,
    "checks": [
        {
            "command": "true",
            "exit_code": 0,
            "output": "",
            "passed": true,
            "type": "test"
        }
    ]
}
JSON

    run generate_failure_context "$result_file"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "" ]]
}

@test "generate_failure_context truncates long output to 500 chars" {
    # Generate output longer than 500 chars
    local long_output
    long_output="$(printf 'X%.0s' {1..600})"

    local result_file="$TEST_DIR/result.json"
    jq -n --arg output "$long_output" '{
        "iteration": 1,
        "strategy": "strict",
        "passed": false,
        "checks": [{
            "command": "failing-test",
            "exit_code": 1,
            "output": $output,
            "passed": false,
            "type": "test"
        }]
    }' > "$result_file"

    run generate_failure_context "$result_file"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"..."* ]]
    # The error line should not contain the full 600 chars
    # (500 chars + "..." + prefix should be less than 600 + overhead)
    local error_line
    error_line="$(echo "$output" | grep "Error:")"
    # Verify truncation happened — the X-sequence in the Error line should be 500 chars
    local x_count
    x_count="$(echo "$error_line" | tr -cd 'X' | wc -c | tr -d ' ')"
    [[ "$x_count" -eq 500 ]]
}

@test "generate_failure_context handles multiple failures" {
    local result_file="$TEST_DIR/result.json"
    cat > "$result_file" <<'JSON'
{
    "iteration": 3,
    "strategy": "strict",
    "passed": false,
    "checks": [
        {
            "command": "bats tests/",
            "exit_code": 1,
            "output": "test failure output",
            "passed": false,
            "type": "test"
        },
        {
            "command": "shellcheck script.sh",
            "exit_code": 1,
            "output": "lint error output",
            "passed": false,
            "type": "lint"
        }
    ]
}
JSON

    run generate_failure_context "$result_file"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"- Check: bats tests/"* ]]
    [[ "$output" == *"- Check: shellcheck script.sh"* ]]
}

@test "generate_failure_context returns empty for nonexistent file" {
    run generate_failure_context "$TEST_DIR/nonexistent.json"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "" ]]
}
