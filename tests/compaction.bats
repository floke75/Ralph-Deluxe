#!/usr/bin/env bats

# tests/compaction.bats — Tests for .ralph/lib/compaction.sh

PROJ_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    # Create a temp dir for each test
    TEST_DIR=$(mktemp -d)
    export TEST_DIR

    # Copy fixtures
    cp -r "$PROJ_ROOT/tests/fixtures" "$TEST_DIR/fixtures"

    # Create mock handoffs directory
    mkdir -p "$TEST_DIR/handoffs"
    cp "$TEST_DIR/fixtures/sample-handoff.json" "$TEST_DIR/handoffs/handoff-003.json"
    cp "$TEST_DIR/fixtures/sample-handoff-002.json" "$TEST_DIR/handoffs/handoff-004.json"

    # Source the module under test
    source "$PROJ_ROOT/.ralph/lib/compaction.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# --- check_compaction_trigger ---

@test "check_compaction_trigger fires on needs_docs task metadata" {
    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task-needs-docs.json")
    run check_compaction_trigger "$TEST_DIR/fixtures/sample-state-below-threshold.json" "$task_json"
    [[ "$status" -eq 0 ]]
}

@test "check_compaction_trigger fires on non-empty libraries" {
    local task_json='{"needs_docs": false, "libraries": ["some-lib"]}'
    run check_compaction_trigger "$TEST_DIR/fixtures/sample-state-below-threshold.json" "$task_json"
    [[ "$status" -eq 0 ]]
}

@test "check_compaction_trigger fires on byte threshold exceeded" {
    local task_json='{"needs_docs": false, "libraries": []}'
    run check_compaction_trigger "$TEST_DIR/fixtures/sample-state-high-bytes.json" "$task_json"
    [[ "$status" -eq 0 ]]
}

@test "check_compaction_trigger fires on periodic interval" {
    local task_json='{"needs_docs": false, "libraries": []}'
    # sample-state.json has coding_iterations_since_compaction = 5
    run check_compaction_trigger "$TEST_DIR/fixtures/sample-state.json" "$task_json"
    [[ "$status" -eq 0 ]]
}

@test "check_compaction_trigger does not fire when below all thresholds" {
    local task_json='{"needs_docs": false, "libraries": []}'
    run check_compaction_trigger "$TEST_DIR/fixtures/sample-state-below-threshold.json" "$task_json"
    [[ "$status" -eq 1 ]]
}

@test "check_compaction_trigger does not fire with no task and low state" {
    run check_compaction_trigger "$TEST_DIR/fixtures/sample-state-below-threshold.json" ""
    [[ "$status" -eq 1 ]]
}

# --- extract_l1 ---

@test "extract_l1 produces one-line summary with task ID" {
    run extract_l1 "$TEST_DIR/fixtures/sample-handoff.json"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"[TASK-003]"* ]]
}

@test "extract_l1 includes completion status" {
    run extract_l1 "$TEST_DIR/fixtures/sample-handoff.json"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Complete"* ]]
}

@test "extract_l1 shows Partial for incomplete tasks" {
    run extract_l1 "$TEST_DIR/fixtures/sample-handoff-002.json"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Partial"* ]]
}

@test "extract_l1 includes file count" {
    run extract_l1 "$TEST_DIR/fixtures/sample-handoff.json"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"3 files"* ]]
}

@test "extract_l1 includes summary text" {
    run extract_l1 "$TEST_DIR/fixtures/sample-handoff.json"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Implemented git-ops.sh"* ]]
}

# --- extract_l2 ---

@test "extract_l2 produces JSON with task field" {
    run extract_l2 "$TEST_DIR/fixtures/sample-handoff.json"
    [[ "$status" -eq 0 ]]
    local task_id
    task_id=$(echo "$output" | jq -r '.task')
    [[ "$task_id" == "TASK-003" ]]
}

@test "extract_l2 includes architectural decisions" {
    run extract_l2 "$TEST_DIR/fixtures/sample-handoff.json"
    [[ "$status" -eq 0 ]]
    local decision_count
    decision_count=$(echo "$output" | jq '.decisions | length')
    [[ "$decision_count" -eq 2 ]]
}

@test "extract_l2 includes deviations" {
    run extract_l2 "$TEST_DIR/fixtures/sample-handoff.json"
    [[ "$status" -eq 0 ]]
    local deviation_count
    deviation_count=$(echo "$output" | jq '.deviations | length')
    [[ "$deviation_count" -eq 1 ]]
}

@test "extract_l2 includes constraints with workarounds" {
    run extract_l2 "$TEST_DIR/fixtures/sample-handoff.json"
    [[ "$status" -eq 0 ]]
    local constraint
    constraint=$(echo "$output" | jq -r '.constraints[0]')
    [[ "$constraint" == *"git clean"* ]]
    [[ "$constraint" == *"--exclude"* ]]
}

@test "extract_l2 captures unresolved bugs in failed array" {
    run extract_l2 "$TEST_DIR/fixtures/sample-handoff-002.json"
    [[ "$status" -eq 0 ]]
    local failed_count
    failed_count=$(echo "$output" | jq '.failed | length')
    [[ "$failed_count" -eq 1 ]]
    [[ "$(echo "$output" | jq -r '.failed[0]')" == *"jq amendment"* ]]
}

@test "extract_l2 captures unfinished business" {
    run extract_l2 "$TEST_DIR/fixtures/sample-handoff-002.json"
    [[ "$status" -eq 0 ]]
    local unfinished_count
    unfinished_count=$(echo "$output" | jq '.unfinished | length')
    [[ "$unfinished_count" -eq 1 ]]
}

# --- extract_l3 ---

@test "extract_l3 returns the file path" {
    run extract_l3 "$TEST_DIR/fixtures/sample-handoff.json"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "$TEST_DIR/fixtures/sample-handoff.json" ]]
}

# --- build_compaction_input ---

@test "build_compaction_input includes handoffs since last compaction" {
    # State has last_compaction_iteration=0, so handoffs 003 and 004 should be included
    run build_compaction_input "$TEST_DIR/handoffs" "$TEST_DIR/fixtures/sample-state.json"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"TASK-003"* ]]
    [[ "$output" == *"TASK-004"* ]]
}

@test "build_compaction_input excludes handoffs before last compaction" {
    # Create a state where last_compaction_iteration=3
    local state_file="$TEST_DIR/state-compact.json"
    cat > "$state_file" <<'EOF'
{
  "current_iteration": 5,
  "last_compaction_iteration": 3,
  "coding_iterations_since_compaction": 2,
  "total_handoff_bytes_since_compaction": 5000,
  "last_task_id": "TASK-004",
  "started_at": "2026-02-06T10:00:00Z",
  "status": "running"
}
EOF
    run build_compaction_input "$TEST_DIR/handoffs" "$state_file"
    [[ "$status" -eq 0 ]]
    # Should include handoff-004 (iter 4 > 3) but not handoff-003 (iter 3 == 3)
    [[ "$output" == *"TASK-004"* ]]
    [[ "$output" != *"TASK-003"* ]]
}

@test "build_compaction_input returns empty when no handoffs exist" {
    local empty_dir
    empty_dir=$(mktemp -d)
    run build_compaction_input "$empty_dir" "$TEST_DIR/fixtures/sample-state.json"
    [[ "$status" -eq 0 ]]
    [[ -z "$(echo "$output" | tr -d '[:space:]')" ]]
    rm -rf "$empty_dir"
}

@test "build_compaction_input contains L2 formatted data" {
    run build_compaction_input "$TEST_DIR/handoffs" "$TEST_DIR/fixtures/sample-state.json"
    [[ "$status" -eq 0 ]]
    # L2 output should have JSON structure with decisions
    [[ "$output" == *"decisions"* ]]
    [[ "$output" == *"deviations"* ]]
}

# --- update_compaction_state ---

@test "update_compaction_state resets counters" {
    local state_file="$TEST_DIR/state.json"
    cp "$TEST_DIR/fixtures/sample-state.json" "$state_file"

    run update_compaction_state "$state_file"
    [[ "$status" -eq 0 ]]

    local iterations_since
    iterations_since=$(jq -r '.coding_iterations_since_compaction' "$state_file")
    [[ "$iterations_since" -eq 0 ]]

    local bytes_since
    bytes_since=$(jq -r '.total_handoff_bytes_since_compaction' "$state_file")
    [[ "$bytes_since" -eq 0 ]]
}

@test "update_compaction_state sets last_compaction_iteration to current_iteration" {
    local state_file="$TEST_DIR/state.json"
    cp "$TEST_DIR/fixtures/sample-state.json" "$state_file"

    run update_compaction_state "$state_file"
    [[ "$status" -eq 0 ]]

    local last_compact
    last_compact=$(jq -r '.last_compaction_iteration' "$state_file")
    local current
    current=$(jq -r '.current_iteration' "$TEST_DIR/fixtures/sample-state.json")
    [[ "$last_compact" -eq "$current" ]]
}

@test "update_compaction_state preserves other state fields" {
    local state_file="$TEST_DIR/state.json"
    cp "$TEST_DIR/fixtures/sample-state.json" "$state_file"

    run update_compaction_state "$state_file"
    [[ "$status" -eq 0 ]]

    local status_val
    status_val=$(jq -r '.status' "$state_file")
    [[ "$status_val" == "running" ]]

    local task_id
    task_id=$(jq -r '.last_task_id' "$state_file")
    [[ "$task_id" == "TASK-004" ]]
}
