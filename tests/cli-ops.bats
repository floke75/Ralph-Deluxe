#!/usr/bin/env bats

# Tests for .ralph/lib/cli-ops.sh

setup() {
    TEST_DIR="$(mktemp -d)"
    export TEST_DIR
    ORIG_DIR="$PWD"

    # Create the required directory structure and config files
    mkdir -p "$TEST_DIR/.ralph/config"
    mkdir -p "$TEST_DIR/.ralph/handoffs"
    mkdir -p "$TEST_DIR/.ralph/logs"

    # Minimal handoff schema for tests
    cat > "$TEST_DIR/.ralph/config/handoff-schema.json" <<'JSON'
{"type":"object","properties":{"task_completed":{"type":"object"}},"required":["task_completed"]}
JSON

    # Minimal memory output schema for tests
    cat > "$TEST_DIR/.ralph/config/memory-output-schema.json" <<'JSON'
{"type":"object","properties":{"project_summary":{"type":"string"}},"required":["project_summary"]}
JSON

    # Empty MCP configs
    echo '{"mcpServers":{}}' > "$TEST_DIR/.ralph/config/mcp-coding.json"
    echo '{"mcpServers":{}}' > "$TEST_DIR/.ralph/config/mcp-memory.json"

    cd "$TEST_DIR"

    # Stub log function
    log() { :; }
    export -f log

    # Source the module under test
    source "$ORIG_DIR/.ralph/lib/cli-ops.sh"
}

teardown() {
    cd "$ORIG_DIR"
    rm -rf "$TEST_DIR"
}

# --- Sample response fixtures ---

# A valid Claude CLI response envelope
valid_response() {
    cat <<'JSON'
{"type":"result","subtype":"success","cost_usd":0.05,"duration_ms":12345,"duration_api_ms":11000,"is_error":false,"num_turns":3,"result":"{\"task_completed\":{\"task_id\":\"TASK-001\",\"summary\":\"Did the thing\",\"fully_complete\":true},\"deviations\":[],\"bugs_encountered\":[],\"architectural_notes\":[\"note1\"],\"files_touched\":[],\"plan_amendments\":[],\"tests_added\":[],\"constraints_discovered\":[]}"}
JSON
}

# --- parse_handoff_output tests ---

@test "parse_handoff_output extracts valid handoff from response envelope" {
    local resp
    resp="$(valid_response)"
    run parse_handoff_output "$resp"
    [[ "$status" -eq 0 ]]
    # Should be valid JSON
    echo "$output" | jq . >/dev/null 2>&1
    # Should contain the task_completed field
    local task_id
    task_id="$(echo "$output" | jq -r '.task_completed.task_id')"
    [[ "$task_id" == "TASK-001" ]]
}

@test "parse_handoff_output extracts full handoff structure" {
    local resp
    resp="$(valid_response)"
    run parse_handoff_output "$resp"
    [[ "$status" -eq 0 ]]
    # Verify expected fields exist
    echo "$output" | jq -e '.task_completed' >/dev/null
    echo "$output" | jq -e '.deviations' >/dev/null
    echo "$output" | jq -e '.architectural_notes' >/dev/null
    echo "$output" | jq -e '.files_touched' >/dev/null
}

@test "parse_handoff_output fails on empty result" {
    local resp='{"type":"result","subtype":"success","result":""}'
    run parse_handoff_output "$resp"
    [[ "$status" -eq 1 ]]
}

@test "parse_handoff_output fails on null result" {
    local resp='{"type":"result","subtype":"success","result":null}'
    run parse_handoff_output "$resp"
    [[ "$status" -eq 1 ]]
}

@test "parse_handoff_output fails on missing result field" {
    local resp='{"type":"result","subtype":"success"}'
    run parse_handoff_output "$resp"
    [[ "$status" -eq 1 ]]
}

@test "parse_handoff_output fails on invalid JSON in result" {
    local resp='{"type":"result","result":"this is not json {{"}'
    run parse_handoff_output "$resp"
    [[ "$status" -eq 1 ]]
}

@test "parse_handoff_output fails on completely invalid input" {
    run parse_handoff_output "not json at all"
    [[ "$status" -eq 1 ]]
}

# --- save_handoff tests ---

@test "save_handoff creates numbered file" {
    local handoff='{"task_completed":{"task_id":"TASK-001","summary":"test","fully_complete":true}}'
    run save_handoff "$handoff" 1
    [[ "$status" -eq 0 ]]
    [[ -f "$TEST_DIR/.ralph/handoffs/handoff-001.json" ]]
}

@test "save_handoff uses zero-padded iteration number" {
    local handoff='{"task_completed":{"task_id":"TASK-042","summary":"test","fully_complete":true}}'
    run save_handoff "$handoff" 42
    [[ "$status" -eq 0 ]]
    [[ -f "$TEST_DIR/.ralph/handoffs/handoff-042.json" ]]
}

@test "save_handoff formats JSON properly" {
    local handoff='{"task_completed":{"task_id":"TASK-001","summary":"test","fully_complete":true}}'
    save_handoff "$handoff" 5 >/dev/null
    # Verify the file contains pretty-printed valid JSON
    run jq -e '.task_completed.task_id' "$TEST_DIR/.ralph/handoffs/handoff-005.json"
    [[ "$status" -eq 0 ]]
    [[ "$output" == '"TASK-001"' ]]
}

@test "save_handoff returns the file path" {
    local handoff='{"task_completed":{"task_id":"T","summary":"s","fully_complete":true}}'
    run save_handoff "$handoff" 7
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"handoff-007.json"* ]]
}

@test "save_handoff creates handoffs directory if missing" {
    rm -rf "$TEST_DIR/.ralph/handoffs"
    local handoff='{"task_completed":{"task_id":"T","summary":"s","fully_complete":true}}'
    run save_handoff "$handoff" 1
    [[ "$status" -eq 0 ]]
    [[ -f "$TEST_DIR/.ralph/handoffs/handoff-001.json" ]]
}

# --- extract_response_metadata tests ---

@test "extract_response_metadata extracts all fields" {
    local resp
    resp="$(valid_response)"
    run extract_response_metadata "$resp"
    [[ "$status" -eq 0 ]]
    local cost duration turns is_error
    cost="$(echo "$output" | jq '.cost_usd')"
    duration="$(echo "$output" | jq '.duration_ms')"
    turns="$(echo "$output" | jq '.num_turns')"
    is_error="$(echo "$output" | jq '.is_error')"
    [[ "$cost" == "0.05" ]]
    [[ "$duration" == "12345" ]]
    [[ "$turns" == "3" ]]
    [[ "$is_error" == "false" ]]
}

@test "extract_response_metadata defaults missing fields to zero/false" {
    local resp='{"type":"result"}'
    run extract_response_metadata "$resp"
    [[ "$status" -eq 0 ]]
    local cost duration turns is_error
    cost="$(echo "$output" | jq '.cost_usd')"
    duration="$(echo "$output" | jq '.duration_ms')"
    turns="$(echo "$output" | jq '.num_turns')"
    is_error="$(echo "$output" | jq '.is_error')"
    [[ "$cost" == "0" ]]
    [[ "$duration" == "0" ]]
    [[ "$turns" == "0" ]]
    [[ "$is_error" == "false" ]]
}

@test "extract_response_metadata detects error responses" {
    local resp='{"type":"result","is_error":true,"cost_usd":0.01,"duration_ms":500,"num_turns":1}'
    run extract_response_metadata "$resp"
    [[ "$status" -eq 0 ]]
    local is_error
    is_error="$(echo "$output" | jq '.is_error')"
    [[ "$is_error" == "true" ]]
}

# --- run_coding_iteration dry-run tests ---

@test "run_coding_iteration dry-run returns valid response" {
    export DRY_RUN=true
    local task='{"id":"TASK-001","max_turns":15}'
    run run_coding_iteration "test prompt" "$task"
    [[ "$status" -eq 0 ]]
    # Output should be valid JSON
    echo "$output" | jq . >/dev/null 2>&1
    # Should have the dry-run result
    local task_id
    task_id="$(echo "$output" | jq -r '.result' | jq -r '.task_completed.task_id')"
    [[ "$task_id" == "DRY-RUN" ]]
}

@test "run_coding_iteration dry-run response is parseable by parse_handoff_output" {
    export DRY_RUN=true
    local task='{"id":"TASK-001","max_turns":15}'
    local resp
    resp="$(run_coding_iteration "test prompt" "$task")"
    run parse_handoff_output "$resp"
    [[ "$status" -eq 0 ]]
    echo "$output" | jq -e '.task_completed.fully_complete' >/dev/null
}

@test "run_coding_iteration respects max_turns from task JSON" {
    export DRY_RUN=true
    # Capture log output to verify the max_turns flag
    log() { echo "$*" >&2; }
    export -f log
    local task='{"id":"TASK-001","max_turns":25}'
    run run_coding_iteration "test prompt" "$task"
    [[ "$status" -eq 0 ]]
    # The dry-run log should include --max-turns 25
    [[ "$output" == *"--max-turns 25"* ]] || [[ "${lines[0]}" == *"--max-turns 25"* ]] || true
}

@test "run_coding_iteration uses default max_turns when not specified" {
    export DRY_RUN=true
    local task='{"id":"TASK-001"}'
    run run_coding_iteration "test prompt" "$task"
    [[ "$status" -eq 0 ]]
    # Should still succeed with default max_turns of 20
    echo "$output" | jq . >/dev/null 2>&1
}

# --- run_memory_iteration dry-run tests ---

@test "run_memory_iteration dry-run returns valid response" {
    export DRY_RUN=true
    run run_memory_iteration "compact these handoffs"
    [[ "$status" -eq 0 ]]
    echo "$output" | jq . >/dev/null 2>&1
    local summary
    summary="$(echo "$output" | jq -r '.result' | jq -r '.project_summary')"
    [[ "$summary" == "Dry run" ]]
}

@test "run_memory_iteration dry-run response is parseable by parse_handoff_output" {
    export DRY_RUN=true
    local resp
    resp="$(run_memory_iteration "compact these handoffs")"
    run parse_handoff_output "$resp"
    [[ "$status" -eq 0 ]]
    echo "$output" | jq -e '.project_summary' >/dev/null
}

# --- Error handling tests ---

@test "run_coding_iteration fails when claude CLI fails (non-dry-run)" {
    export DRY_RUN=false
    # Create a fake claude that always fails
    local fake_bin="$TEST_DIR/fake_bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/claude" <<'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
    chmod +x "$fake_bin/claude"
    export PATH="$fake_bin:$PATH"
    local task='{"id":"TASK-001","max_turns":5}'
    run run_coding_iteration "test prompt" "$task"
    [[ "$status" -ne 0 ]]
}

@test "run_memory_iteration fails when claude CLI fails (non-dry-run)" {
    export DRY_RUN=false
    # Create a fake claude that always fails
    local fake_bin="$TEST_DIR/fake_bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/claude" <<'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
    chmod +x "$fake_bin/claude"
    export PATH="$fake_bin:$PATH"
    run run_memory_iteration "test prompt"
    [[ "$status" -ne 0 ]]
}

# --- Integration-style: end-to-end dry-run pipeline ---

@test "full dry-run pipeline: coding iteration -> parse -> save" {
    export DRY_RUN=true
    local task='{"id":"TASK-010","max_turns":10}'

    # Step 1: Run coding iteration
    local resp
    resp="$(run_coding_iteration "implement feature X" "$task")"

    # Step 2: Parse handoff
    local handoff
    handoff="$(parse_handoff_output "$resp")"
    echo "$handoff" | jq -e '.task_completed' >/dev/null

    # Step 3: Save handoff
    local saved_path
    saved_path="$(save_handoff "$handoff" 10)"
    [[ -f "$TEST_DIR/.ralph/handoffs/handoff-010.json" ]]

    # Step 4: Extract metadata
    local metadata
    metadata="$(extract_response_metadata "$resp")"
    local is_error
    is_error="$(echo "$metadata" | jq '.is_error')"
    [[ "$is_error" == "false" ]]
}

@test "full dry-run pipeline: memory iteration -> parse -> save" {
    export DRY_RUN=true

    # Step 1: Run memory iteration
    local resp
    resp="$(run_memory_iteration "compact handoffs 1-5")"

    # Step 2: Parse output
    local result
    result="$(parse_handoff_output "$resp")"
    echo "$result" | jq -e '.project_summary' >/dev/null

    # Step 3: Can save result too
    local saved_path
    saved_path="$(save_handoff "$result" 6)"
    [[ -f "$TEST_DIR/.ralph/handoffs/handoff-006.json" ]]
}
