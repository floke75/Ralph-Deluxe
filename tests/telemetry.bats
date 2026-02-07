#!/usr/bin/env bats

# tests/telemetry.bats — Tests for .ralph/lib/telemetry.sh

PROJ_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    TEST_DIR=$(mktemp -d)
    export TEST_DIR

    # Set up telemetry paths in the temp dir
    export RALPH_EVENTS_FILE="$TEST_DIR/.ralph/logs/events.jsonl"
    export RALPH_CONTROL_FILE="$TEST_DIR/.ralph/control/commands.json"
    export RALPH_PAUSE_POLL_SECONDS=0

    # Create directory structure
    mkdir -p "$TEST_DIR/.ralph/logs"
    mkdir -p "$TEST_DIR/.ralph/control"

    # Source the module under test
    source "$PROJ_ROOT/.ralph/lib/telemetry.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# --- emit_event ---

@test "emit_event creates events.jsonl file" {
    emit_event "test_event" "hello world"
    [[ -f "$RALPH_EVENTS_FILE" ]]
}

@test "emit_event writes valid JSON line" {
    emit_event "test_event" "hello world"
    local line
    line="$(head -1 "$RALPH_EVENTS_FILE")"
    echo "$line" | jq . >/dev/null 2>&1
    [[ $? -eq 0 ]]
}

@test "emit_event includes timestamp field" {
    emit_event "test_event" "hello"
    local ts
    ts="$(head -1 "$RALPH_EVENTS_FILE" | jq -r '.timestamp')"
    [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "emit_event includes event type" {
    emit_event "iteration_start" "Starting iteration 1"
    local event_type
    event_type="$(head -1 "$RALPH_EVENTS_FILE" | jq -r '.event')"
    [[ "$event_type" == "iteration_start" ]]
}

@test "emit_event includes message" {
    emit_event "test_event" "My test message"
    local msg
    msg="$(head -1 "$RALPH_EVENTS_FILE" | jq -r '.message')"
    [[ "$msg" == "My test message" ]]
}

@test "emit_event includes default empty metadata when none provided" {
    emit_event "test_event" "hello"
    local meta
    meta="$(head -1 "$RALPH_EVENTS_FILE" | jq -c '.metadata')"
    [[ "$meta" == "{}" ]]
}

@test "emit_event includes custom metadata" {
    emit_event "iteration_start" "Starting" '{"iteration":1,"task_id":"TASK-001"}'
    local task_id
    task_id="$(head -1 "$RALPH_EVENTS_FILE" | jq -r '.metadata.task_id')"
    [[ "$task_id" == "TASK-001" ]]
    local iter
    iter="$(head -1 "$RALPH_EVENTS_FILE" | jq -r '.metadata.iteration')"
    [[ "$iter" == "1" ]]
}

@test "emit_event appends multiple events" {
    emit_event "event_one" "first"
    emit_event "event_two" "second"
    emit_event "event_three" "third"
    local count
    count="$(wc -l < "$RALPH_EVENTS_FILE" | tr -d ' ')"
    [[ "$count" -eq 3 ]]
}

@test "emit_event creates parent directory if missing" {
    rm -rf "$TEST_DIR/.ralph/logs"
    emit_event "test_event" "auto-create dir"
    [[ -f "$RALPH_EVENTS_FILE" ]]
}

# --- init_control_file ---

@test "init_control_file creates commands.json with empty pending array" {
    rm -f "$RALPH_CONTROL_FILE"
    init_control_file
    [[ -f "$RALPH_CONTROL_FILE" ]]
    local pending_count
    pending_count="$(jq '.pending | length' "$RALPH_CONTROL_FILE")"
    [[ "$pending_count" -eq 0 ]]
}

@test "init_control_file does not overwrite existing file" {
    echo '{"pending":[{"command":"pause"}]}' | jq . > "$RALPH_CONTROL_FILE"
    init_control_file
    local pending_count
    pending_count="$(jq '.pending | length' "$RALPH_CONTROL_FILE")"
    [[ "$pending_count" -eq 1 ]]
}

@test "init_control_file creates parent directory if missing" {
    rm -rf "$TEST_DIR/.ralph/control"
    init_control_file
    [[ -f "$RALPH_CONTROL_FILE" ]]
}

# --- read_pending_commands ---

@test "read_pending_commands returns empty array when no file exists" {
    rm -f "$RALPH_CONTROL_FILE"
    run read_pending_commands
    [[ "$status" -eq 0 ]]
    [[ "$output" == "[]" ]]
}

@test "read_pending_commands returns empty array for empty pending" {
    echo '{"pending":[]}' > "$RALPH_CONTROL_FILE"
    run read_pending_commands
    [[ "$status" -eq 0 ]]
    [[ "$output" == "[]" ]]
}

@test "read_pending_commands returns pending commands" {
    cat > "$RALPH_CONTROL_FILE" <<'EOF'
{"pending":[{"command":"pause"},{"command":"inject-note","note":"test"}]}
EOF
    run read_pending_commands
    [[ "$status" -eq 0 ]]
    local count
    count="$(echo "$output" | jq 'length')"
    [[ "$count" -eq 2 ]]
}

# --- clear_pending_commands ---

@test "clear_pending_commands empties the pending array" {
    cat > "$RALPH_CONTROL_FILE" <<'EOF'
{"pending":[{"command":"pause"},{"command":"resume"}]}
EOF
    clear_pending_commands
    local count
    count="$(jq '.pending | length' "$RALPH_CONTROL_FILE")"
    [[ "$count" -eq 0 ]]
}

@test "clear_pending_commands is safe when file does not exist" {
    rm -f "$RALPH_CONTROL_FILE"
    run clear_pending_commands
    [[ "$status" -eq 0 ]]
}

# --- process_control_commands ---

@test "process_control_commands sets RALPH_PAUSED on pause command" {
    RALPH_PAUSED=false
    cat > "$RALPH_CONTROL_FILE" <<'EOF'
{"pending":[{"command":"pause"}]}
EOF
    process_control_commands
    [[ "$RALPH_PAUSED" == "true" ]]
}

@test "process_control_commands clears RALPH_PAUSED on resume command" {
    RALPH_PAUSED=true
    cat > "$RALPH_CONTROL_FILE" <<'EOF'
{"pending":[{"command":"resume"}]}
EOF
    process_control_commands
    [[ "$RALPH_PAUSED" == "false" ]]
}

@test "process_control_commands emits pause event" {
    RALPH_PAUSED=false
    cat > "$RALPH_CONTROL_FILE" <<'EOF'
{"pending":[{"command":"pause"}]}
EOF
    process_control_commands
    local event_type
    event_type="$(head -1 "$RALPH_EVENTS_FILE" | jq -r '.event')"
    [[ "$event_type" == "pause" ]]
}

@test "process_control_commands emits resume event" {
    RALPH_PAUSED=true
    cat > "$RALPH_CONTROL_FILE" <<'EOF'
{"pending":[{"command":"resume"}]}
EOF
    process_control_commands
    local event_type
    event_type="$(head -1 "$RALPH_EVENTS_FILE" | jq -r '.event')"
    [[ "$event_type" == "resume" ]]
}

@test "process_control_commands handles inject-note" {
    cat > "$RALPH_CONTROL_FILE" <<'EOF'
{"pending":[{"command":"inject-note","note":"Operator says hello"}]}
EOF
    process_control_commands
    local event_type
    event_type="$(head -1 "$RALPH_EVENTS_FILE" | jq -r '.event')"
    [[ "$event_type" == "note" ]]
    local msg
    msg="$(head -1 "$RALPH_EVENTS_FILE" | jq -r '.message')"
    [[ "$msg" == "Operator says hello" ]]
}

@test "process_control_commands clears pending after processing" {
    cat > "$RALPH_CONTROL_FILE" <<'EOF'
{"pending":[{"command":"pause"},{"command":"inject-note","note":"hi"}]}
EOF
    process_control_commands
    local count
    count="$(jq '.pending | length' "$RALPH_CONTROL_FILE")"
    [[ "$count" -eq 0 ]]
}

@test "process_control_commands handles multiple commands in order" {
    RALPH_PAUSED=false
    cat > "$RALPH_CONTROL_FILE" <<'EOF'
{"pending":[{"command":"inject-note","note":"first"},{"command":"pause"},{"command":"inject-note","note":"second"}]}
EOF
    process_control_commands
    [[ "$RALPH_PAUSED" == "true" ]]
    local line_count
    line_count="$(wc -l < "$RALPH_EVENTS_FILE" | tr -d ' ')"
    [[ "$line_count" -eq 3 ]]
}

@test "process_control_commands does nothing with empty pending" {
    echo '{"pending":[]}' > "$RALPH_CONTROL_FILE"
    run process_control_commands
    [[ "$status" -eq 0 ]]
    [[ ! -f "$RALPH_EVENTS_FILE" ]]
}

@test "process_control_commands ignores unknown commands" {
    cat > "$RALPH_CONTROL_FILE" <<'EOF'
{"pending":[{"command":"unknown-cmd"}]}
EOF
    run process_control_commands
    [[ "$status" -eq 0 ]]
}

# --- wait_while_paused ---

@test "wait_while_paused returns immediately when not paused" {
    RALPH_PAUSED=false
    run wait_while_paused
    [[ "$status" -eq 0 ]]
}

@test "wait_while_paused resumes when resume command appears" {
    RALPH_PAUSED=true

    # Write a resume command to the control file after a short delay
    (sleep 0.1 && echo '{"pending":[{"command":"resume"}]}' > "$RALPH_CONTROL_FILE") &
    local bg_pid=$!

    wait_while_paused
    wait "$bg_pid" 2>/dev/null || true

    [[ "$RALPH_PAUSED" == "false" ]]
}

# --- check_and_handle_commands ---

@test "check_and_handle_commands returns immediately with no commands" {
    echo '{"pending":[]}' > "$RALPH_CONTROL_FILE"
    RALPH_PAUSED=false
    run check_and_handle_commands
    [[ "$status" -eq 0 ]]
}

@test "check_and_handle_commands processes commands and continues" {
    cat > "$RALPH_CONTROL_FILE" <<'EOF'
{"pending":[{"command":"inject-note","note":"test note"}]}
EOF
    RALPH_PAUSED=false
    check_and_handle_commands
    local event_type
    event_type="$(head -1 "$RALPH_EVENTS_FILE" | jq -r '.event')"
    [[ "$event_type" == "note" ]]
}

# --- JSONL stream integrity ---

@test "events.jsonl stream has one valid JSON object per line" {
    emit_event "start" "Begin" '{"iter":1}'
    emit_event "note" "Middle note"
    emit_event "end" "Done" '{"status":"complete"}'

    # Verify each line is valid JSON
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        echo "$line" | jq . >/dev/null 2>&1
        [[ $? -eq 0 ]]
    done < "$RALPH_EVENTS_FILE"
    [[ "$line_num" -eq 3 ]]
}

@test "events.jsonl preserves event ordering" {
    emit_event "first" "1"
    emit_event "second" "2"
    emit_event "third" "3"

    local first_type second_type third_type
    first_type="$(sed -n '1p' "$RALPH_EVENTS_FILE" | jq -r '.event')"
    second_type="$(sed -n '2p' "$RALPH_EVENTS_FILE" | jq -r '.event')"
    third_type="$(sed -n '3p' "$RALPH_EVENTS_FILE" | jq -r '.event')"
    [[ "$first_type" == "first" ]]
    [[ "$second_type" == "second" ]]
    [[ "$third_type" == "third" ]]
}
