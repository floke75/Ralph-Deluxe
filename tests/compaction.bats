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

    # Create .ralph structure for knowledge indexer tests
    export RALPH_DIR="$TEST_DIR/.ralph"
    mkdir -p "$RALPH_DIR/handoffs"
    mkdir -p "$RALPH_DIR/templates"
    cp "$TEST_DIR/handoffs/handoff-003.json" "$RALPH_DIR/handoffs/"
    cp "$TEST_DIR/handoffs/handoff-004.json" "$RALPH_DIR/handoffs/"
    cp "$PROJ_ROOT/.ralph/templates/knowledge-index-prompt.md" "$RALPH_DIR/templates/"

    # Create state file for knowledge indexer tests
    export STATE_FILE="$RALPH_DIR/state.json"
    cp "$TEST_DIR/fixtures/sample-state.json" "$STATE_FILE"

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


@test "check_compaction_trigger does not fire novelty trigger on high overlap" {
    mkdir -p "$TEST_DIR/.ralph/handoffs"
    cp "$TEST_DIR/fixtures/sample-handoff.json" "$TEST_DIR/.ralph/handoffs/handoff-001.json"
    cp "$TEST_DIR/fixtures/sample-handoff-002.json" "$TEST_DIR/.ralph/handoffs/handoff-002.json"
    export RALPH_DIR="$TEST_DIR/.ralph"

    local task_json='{"title":"Implement git rollback helpers","description":"Add git clean reset and checkpoint rollback to git operations module","libraries":[]}'
    run check_compaction_trigger "$TEST_DIR/fixtures/sample-state-below-threshold.json" "$task_json"
    [[ "$status" -eq 1 ]]
}

@test "check_compaction_trigger fires novelty trigger on low overlap" {
    mkdir -p "$TEST_DIR/.ralph/handoffs"
    cp "$TEST_DIR/fixtures/sample-handoff.json" "$TEST_DIR/.ralph/handoffs/handoff-001.json"
    cp "$TEST_DIR/fixtures/sample-handoff-002.json" "$TEST_DIR/.ralph/handoffs/handoff-002.json"
    export RALPH_DIR="$TEST_DIR/.ralph"

    local task_json='{"title":"Create websocket telemetry dashboard","description":"Build streaming metrics panel for browser clients","libraries":[]}'
    run check_compaction_trigger "$TEST_DIR/fixtures/sample-state-below-threshold.json" "$task_json"
    [[ "$status" -eq 0 ]]
}

@test "check_compaction_trigger metadata trigger has priority over novelty" {
    mkdir -p "$TEST_DIR/.ralph/handoffs"
    cp "$TEST_DIR/fixtures/sample-handoff.json" "$TEST_DIR/.ralph/handoffs/handoff-001.json"
    cp "$TEST_DIR/fixtures/sample-handoff-002.json" "$TEST_DIR/.ralph/handoffs/handoff-002.json"
    export RALPH_DIR="$TEST_DIR/.ralph"

    local task_json='{"needs_docs": true, "title":"Create websocket telemetry dashboard", "description":"Build streaming metrics panel for browser clients", "libraries":[]}'
    run check_compaction_trigger "$TEST_DIR/fixtures/sample-state-below-threshold.json" "$task_json"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"task metadata"* ]]
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

# --- build_indexer_prompt ---

@test "build_indexer_prompt includes template content when template exists" {
    local compaction_input="--- Iteration 3 ---"$'\n'"test data"
    run build_indexer_prompt "$compaction_input"
    [[ "$status" -eq 0 ]]
    # Template should contain the Knowledge Indexer header
    [[ "$output" == *"Knowledge Indexer"* ]]
    [[ "$output" == *"knowledge-index.md"* ]]
    [[ "$output" == *"knowledge-index.json"* ]]
}

@test "build_indexer_prompt includes compaction input data" {
    local compaction_input="--- Iteration 3 ---"$'\n'"TASK-003 test data"
    run build_indexer_prompt "$compaction_input"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"## Recent Handoff Data"* ]]
    [[ "$output" == *"TASK-003 test data"* ]]
}

@test "build_indexer_prompt includes existing knowledge index when present" {
    # Create an existing knowledge index
    cat > "$RALPH_DIR/knowledge-index.md" <<'EOF'
# Knowledge Index
Last updated: iteration 2

## Constraints
- Some existing constraint [iter 2]
EOF

    local compaction_input="--- Iteration 3 ---"$'\n'"new data"
    run build_indexer_prompt "$compaction_input"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"## Existing Knowledge Index"* ]]
    [[ "$output" == *"Some existing constraint"* ]]
}

@test "build_indexer_prompt works without existing knowledge index" {
    # Ensure no knowledge-index.md exists
    rm -f "$RALPH_DIR/knowledge-index.md"

    local compaction_input="--- Iteration 3 ---"$'\n'"data"
    run build_indexer_prompt "$compaction_input"
    [[ "$status" -eq 0 ]]
    # Should not contain existing knowledge index section
    [[ "$output" != *"## Existing Knowledge Index"* ]]
    # Should still contain the handoff data
    [[ "$output" == *"## Recent Handoff Data"* ]]
}

@test "build_indexer_prompt works without template file" {
    rm -f "$RALPH_DIR/templates/knowledge-index-prompt.md"

    local compaction_input="--- Iteration 3 ---"$'\n'"data"
    run build_indexer_prompt "$compaction_input"
    [[ "$status" -eq 0 ]]
    # Should still contain the handoff data section
    [[ "$output" == *"## Recent Handoff Data"* ]]
    [[ "$output" == *"data"* ]]
}

# --- run_knowledge_indexer ---

@test "run_knowledge_indexer returns 0 when no handoffs to index" {
    # Set last_compaction_iteration to 10 so all handoffs are excluded
    local state_file="$RALPH_DIR/state.json"
    cat > "$state_file" <<'EOF'
{
  "current_iteration": 10,
  "last_compaction_iteration": 10,
  "coding_iterations_since_compaction": 0,
  "total_handoff_bytes_since_compaction": 0,
  "last_task_id": "TASK-005",
  "started_at": "2026-02-06T10:00:00Z",
  "status": "running"
}
EOF

    # Mock run_memory_iteration to verify it's NOT called
    run_memory_iteration() { echo "SHOULD NOT BE CALLED"; return 1; }
    export -f run_memory_iteration

    run run_knowledge_indexer ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"No new handoffs to index"* ]]
}

@test "run_knowledge_indexer calls run_memory_iteration with indexer prompt" {
    # Mock run_memory_iteration to capture its input
    run_memory_iteration() {
        local prompt="$1"
        if [[ "$prompt" == *"Recent Handoff Data"* && "$prompt" == *"TASK-003"* ]]; then
            echo '{"type":"result","subtype":"success","result":"{}"}'
            return 0
        fi
        echo "unexpected prompt"
        return 1
    }
    export -f run_memory_iteration

    run run_knowledge_indexer ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Knowledge indexer start"* ]]
    [[ "$output" == *"Knowledge indexer end"* ]]
}

@test "run_knowledge_indexer updates compaction state on success" {
    # Mock run_memory_iteration
    run_memory_iteration() {
        echo '{"type":"result","subtype":"success","result":"{}"}'
        return 0
    }
    export -f run_memory_iteration

    # Verify state before
    local iters_before
    iters_before=$(jq -r '.coding_iterations_since_compaction' "$STATE_FILE")
    [[ "$iters_before" -eq 5 ]]

    run_knowledge_indexer ""

    # Verify state was reset
    local iters_after
    iters_after=$(jq -r '.coding_iterations_since_compaction' "$STATE_FILE")
    [[ "$iters_after" -eq 0 ]]

    local bytes_after
    bytes_after=$(jq -r '.total_handoff_bytes_since_compaction' "$STATE_FILE")
    [[ "$bytes_after" -eq 0 ]]
}

@test "run_knowledge_indexer returns 1 when memory iteration fails" {
    # Mock run_memory_iteration to fail
    run_memory_iteration() { return 1; }
    export -f run_memory_iteration

    run run_knowledge_indexer ""
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Knowledge indexer failed"* ]]
}
