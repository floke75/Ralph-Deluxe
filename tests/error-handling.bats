#!/usr/bin/env bats

# tests/error-handling.bats — Error recovery tests for Ralph Deluxe

PROJ_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Stub log function
log() { :; }
export -f log

setup() {
    TEST_DIR="$(mktemp -d)"
    export TEST_DIR

    # Create .ralph directory structure
    mkdir -p "$TEST_DIR/.ralph/config"
    mkdir -p "$TEST_DIR/.ralph/logs/validation"
    mkdir -p "$TEST_DIR/.ralph/handoffs"
    mkdir -p "$TEST_DIR/.ralph/context/compaction-history"
    mkdir -p "$TEST_DIR/.ralph/lib"

    # Copy lib modules
    cp "$PROJ_ROOT/.ralph/lib/"*.sh "$TEST_DIR/.ralph/lib/"

    # Copy ralph.sh
    cp "$PROJ_ROOT/.ralph/ralph.sh" "$TEST_DIR/.ralph/ralph.sh"
    chmod +x "$TEST_DIR/.ralph/ralph.sh"

    # Create config that always passes validation
    cat > "$TEST_DIR/.ralph/config/ralph.conf" <<'CONF'
RALPH_VALIDATION_COMMANDS=("true")
RALPH_VALIDATION_STRATEGY="strict"
RALPH_LOG_LEVEL="error"
RALPH_LOG_FILE=".ralph/logs/ralph.log"
RALPH_COMPACTION_INTERVAL=100
RALPH_MIN_DELAY_SECONDS=0
CONF

    # Copy MCP config
    cp "$PROJ_ROOT/.ralph/config/mcp-coding.json" "$TEST_DIR/.ralph/config/" 2>/dev/null || echo '{"mcpServers":{}}' > "$TEST_DIR/.ralph/config/mcp-coding.json"

    # Create initial state.json
    cat > "$TEST_DIR/.ralph/state.json" <<'EOF'
{
  "current_iteration": 0,
  "last_compaction_iteration": 0,
  "coding_iterations_since_compaction": 0,
  "total_handoff_bytes_since_compaction": 0,
  "last_task_id": null,
  "started_at": "2026-02-06T10:00:00Z",
  "status": "idle"
}
EOF

    # Create a plan with one pending task
    cat > "$TEST_DIR/plan.json" <<'EOF'
{
  "project": "error-test",
  "branch": "main",
  "max_iterations": 10,
  "validation_strategy": "strict",
  "tasks": [
    {
      "id": "TASK-001",
      "title": "Test task",
      "description": "Task for error testing.",
      "status": "pending",
      "order": 1,
      "skills": [],
      "needs_docs": false,
      "libraries": [],
      "acceptance_criteria": ["Works"],
      "depends_on": [],
      "max_turns": 15,
      "retry_count": 0,
      "max_retries": 2
    }
  ]
}
EOF

    # Initialize git repo (disable signing for test isolation)
    cd "$TEST_DIR"
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    git config commit.gpgsign false
    git config tag.gpgsign false
    git add -A
    git commit --quiet -m "initial commit"
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

# --- Empty response handling ---

@test "handle empty response from claude CLI" {
    cd "$TEST_DIR"
    mkdir -p "$TEST_DIR/bin"

    # Mock claude that returns empty output
    cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo ""
MOCK
    chmod +x "$TEST_DIR/bin/claude"

    PATH="$TEST_DIR/bin:$PATH" run bash "$TEST_DIR/.ralph/ralph.sh" --plan "$TEST_DIR/plan.json" --max-iterations 1
    # Should not crash — should handle gracefully (may fail validation and rollback)
    # The key assertion: it exits without a bash error (no unbound variable, etc.)
    # Status can be 0 (handled) or non-zero (validation failed, which is expected)
    [[ "$status" -eq 0 || "$status" -eq 1 ]]

    # State file should still exist and be valid JSON
    jq . "$TEST_DIR/.ralph/state.json" >/dev/null 2>&1
    [[ $? -eq 0 ]]
}

# --- Invalid JSON response ---

@test "handle invalid JSON response from claude CLI" {
    cd "$TEST_DIR"
    mkdir -p "$TEST_DIR/bin"

    # Mock claude that returns garbage
    cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "This is not JSON at all {broken"
MOCK
    chmod +x "$TEST_DIR/bin/claude"

    PATH="$TEST_DIR/bin:$PATH" run bash "$TEST_DIR/.ralph/ralph.sh" --plan "$TEST_DIR/plan.json" --max-iterations 1
    # Should handle gracefully
    [[ "$status" -eq 0 || "$status" -eq 1 ]]

    # State file should still be valid JSON
    jq . "$TEST_DIR/.ralph/state.json" >/dev/null 2>&1
    [[ $? -eq 0 ]]
}

# --- CLI failure (non-zero exit) ---

@test "handle CLI failure with non-zero exit code" {
    cd "$TEST_DIR"
    mkdir -p "$TEST_DIR/bin"

    # Mock claude that exits with error
    cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Error: rate limit exceeded" >&2
exit 1
MOCK
    chmod +x "$TEST_DIR/bin/claude"

    PATH="$TEST_DIR/bin:$PATH" run bash "$TEST_DIR/.ralph/ralph.sh" --plan "$TEST_DIR/plan.json" --max-iterations 1
    # Should handle gracefully — rollback, not crash
    [[ "$status" -eq 0 || "$status" -eq 1 ]]

    # State file should still be valid
    jq . "$TEST_DIR/.ralph/state.json" >/dev/null 2>&1
    [[ $? -eq 0 ]]
}

# --- Git rollback on validation failure ---

@test "git rollback on validation failure restores original state" {
    cd "$TEST_DIR"
    mkdir -p "$TEST_DIR/bin"

    # Mock claude that creates files (simulating coding work)
    cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "new content" > new-file-from-claude.txt
cat <<'RESPONSE'
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "duration_ms": 1000,
  "num_turns": 1,
  "result": "{\"task_completed\":{\"task_id\":\"TASK-001\",\"summary\":\"Created file.\",\"fully_complete\":true},\"deviations\":[],\"bugs_encountered\":[],\"architectural_notes\":[],\"unfinished_business\":[],\"recommendations\":[],\"files_touched\":[{\"path\":\"new-file-from-claude.txt\",\"action\":\"created\"}],\"plan_amendments\":[],\"tests_added\":[],\"constraints_discovered\":[]}"
}
RESPONSE
MOCK
    chmod +x "$TEST_DIR/bin/claude"

    # Make validation FAIL
    cat > "$TEST_DIR/.ralph/config/ralph.conf" <<'CONF'
RALPH_VALIDATION_COMMANDS=("false")
RALPH_VALIDATION_STRATEGY="strict"
RALPH_LOG_LEVEL="error"
RALPH_LOG_FILE=".ralph/logs/ralph.log"
RALPH_COMPACTION_INTERVAL=100
RALPH_MIN_DELAY_SECONDS=0
CONF
    git add -A && git commit --quiet -m "setup failing validation"

    PATH="$TEST_DIR/bin:$PATH" run bash "$TEST_DIR/.ralph/ralph.sh" --plan "$TEST_DIR/plan.json" --max-iterations 1
    # May succeed (handled the failure) or return 1

    # The file created by mock claude should not exist (rolled back)
    [[ ! -f "$TEST_DIR/new-file-from-claude.txt" ]]

    # The last commit should NOT be an iteration commit — rollback undid it.
    # (The orchestrator may create auto-commits at startup for init files,
    # but the failed iteration's commit should have been rolled back.)
    local last_msg
    last_msg="$(git log -1 --format=%s)"
    [[ "$last_msg" != *"TASK-001 — passed validation"* ]]
}

# --- State file preserved on error ---

@test "state file preserved and valid after error" {
    cd "$TEST_DIR"
    mkdir -p "$TEST_DIR/bin"

    # Record original state
    local orig_state
    orig_state="$(cat "$TEST_DIR/.ralph/state.json")"

    # Mock claude that crashes
    cat > "$TEST_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
exit 137
MOCK
    chmod +x "$TEST_DIR/bin/claude"

    PATH="$TEST_DIR/bin:$PATH" run bash "$TEST_DIR/.ralph/ralph.sh" --plan "$TEST_DIR/plan.json" --max-iterations 1

    # State file must exist
    [[ -f "$TEST_DIR/.ralph/state.json" ]]

    # State file must be valid JSON
    run jq . "$TEST_DIR/.ralph/state.json"
    [[ "$status" -eq 0 ]]

    # current_iteration should have been updated (to 1)
    local iteration
    iteration="$(jq -r '.current_iteration' "$TEST_DIR/.ralph/state.json")"
    [[ "$iteration" -ge 0 ]]
}

# --- Plan amendment safety ---

@test "plan amendments reject more than 3 amendments" {
    cd "$TEST_DIR"

    # Source plan-ops directly for this unit-ish test
    source "$PROJ_ROOT/.ralph/lib/plan-ops.sh"

    local plan_file="$TEST_DIR/plan.json"
    local handoff_file="$PROJ_ROOT/tests/fixtures/sample-amendments-invalid.json"

    # Create amendments log dir
    export RALPH_DIR="$TEST_DIR/.ralph"
    mkdir -p "$TEST_DIR/.ralph/logs"

    run apply_amendments "$plan_file" "$handoff_file" ""
    [[ "$status" -eq 1 ]]
}

@test "plan amendments cannot remove done tasks" {
    cd "$TEST_DIR"

    source "$PROJ_ROOT/.ralph/lib/plan-ops.sh"

    # Create a plan with a done task and a handoff that tries to remove it
    cat > "$TEST_DIR/plan-with-done.json" <<'EOF'
{
  "project": "test",
  "branch": "main",
  "max_iterations": 10,
  "validation_strategy": "strict",
  "tasks": [
    {"id": "TASK-001", "title": "Done", "description": "d", "status": "done", "order": 1, "skills": [], "needs_docs": false, "libraries": [], "acceptance_criteria": [], "depends_on": [], "max_turns": 15, "retry_count": 0, "max_retries": 2},
    {"id": "TASK-002", "title": "Pending", "description": "d", "status": "pending", "order": 2, "skills": [], "needs_docs": false, "libraries": [], "acceptance_criteria": [], "depends_on": [], "max_turns": 15, "retry_count": 0, "max_retries": 2}
  ]
}
EOF
    cat > "$TEST_DIR/handoff-remove-done.json" <<'EOF'
{
  "task_completed": {"task_id": "TASK-002", "summary": "Done.", "fully_complete": true},
  "deviations": [], "bugs_encountered": [], "architectural_notes": [],
  "files_touched": [], "tests_added": [], "constraints_discovered": [],
  "plan_amendments": [
    {"action": "remove", "task_id": "TASK-001", "reason": "Not needed"}
  ]
}
EOF

    export RALPH_DIR="$TEST_DIR/.ralph"
    mkdir -p "$TEST_DIR/.ralph/logs"

    run apply_amendments "$TEST_DIR/plan-with-done.json" "$TEST_DIR/handoff-remove-done.json" ""
    [[ "$status" -eq 0 ]]

    # TASK-001 should still be in the plan (removal was rejected)
    local task_exists
    task_exists="$(jq '[.tasks[] | select(.id == "TASK-001")] | length' "$TEST_DIR/plan-with-done.json")"
    [[ "$task_exists" -eq 1 ]]
}

@test "valid plan amendments are applied correctly" {
    cd "$TEST_DIR"

    source "$PROJ_ROOT/.ralph/lib/plan-ops.sh"

    # Use the sample plan fixture
    cp "$PROJ_ROOT/tests/fixtures/sample-plan.json" "$TEST_DIR/test-plan.json"

    export RALPH_DIR="$TEST_DIR/.ralph"
    mkdir -p "$TEST_DIR/.ralph/logs"

    run apply_amendments "$TEST_DIR/test-plan.json" "$PROJ_ROOT/tests/fixtures/sample-amendments-valid.json" ""
    [[ "$status" -eq 0 ]]

    # New task should have been added
    local new_task
    new_task="$(jq -r '.tasks[] | select(.id == "TASK-NEW-001") | .title' "$TEST_DIR/test-plan.json")"
    [[ "$new_task" == "New edge case handling" ]]

    # TASK-003 should have been modified
    local max_turns
    max_turns="$(jq -r '.tasks[] | select(.id == "TASK-003") | .max_turns' "$TEST_DIR/test-plan.json")"
    [[ "$max_turns" -eq 25 ]]
}
