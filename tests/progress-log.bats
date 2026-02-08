#!/usr/bin/env bats

# Scope: unit tests for progress summary rendering from plan and handoff data.
# Fixture notes: setup creates an inline multi-status plan plus .ralph directories
# in TEST_DIR so progress-log.sh reads predictable local fixtures.


PROJ_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    TEST_DIR="$(mktemp -d)"
    export TEST_DIR

    # Set up .ralph directory structure
    export RALPH_DIR="$TEST_DIR/.ralph"
    export PLAN_FILE="$TEST_DIR/plan.json"
    mkdir -p "$RALPH_DIR"/{handoffs,lib,logs}

    # Create sample plan.json with 3 tasks: 1 done, 1 pending, 1 failed
    cat > "$PLAN_FILE" <<'EOF'
{
  "project": "test-project",
  "branch": "main",
  "max_iterations": 10,
  "validation_strategy": "strict",
  "tasks": [
    {
      "id": "TASK-001",
      "title": "Create directory structure",
      "description": "Set up project layout.",
      "status": "done",
      "order": 1,
      "skills": [],
      "needs_docs": false,
      "libraries": [],
      "acceptance_criteria": ["Dirs exist"],
      "depends_on": [],
      "max_turns": 15,
      "retry_count": 0,
      "max_retries": 2
    },
    {
      "id": "TASK-002",
      "title": "Implement core module",
      "description": "Build the core logic.",
      "status": "pending",
      "order": 2,
      "skills": [],
      "needs_docs": false,
      "libraries": [],
      "acceptance_criteria": ["Tests pass"],
      "depends_on": ["TASK-001"],
      "max_turns": 15,
      "retry_count": 0,
      "max_retries": 2
    },
    {
      "id": "TASK-003",
      "title": "Git operations module",
      "description": "Checkpoint and rollback.",
      "status": "failed",
      "order": 3,
      "skills": [],
      "needs_docs": false,
      "libraries": [],
      "acceptance_criteria": ["Rollback works"],
      "depends_on": [],
      "max_turns": 15,
      "retry_count": 1,
      "max_retries": 2
    }
  ]
}
EOF

    # Create sample handoff JSON with all fields populated
    cat > "$RALPH_DIR/handoffs/handoff-005.json" <<'EOF'
{
  "task_completed": {
    "task_id": "TASK-001",
    "summary": "Created directory structure and initial config files.",
    "fully_complete": true
  },
  "deviations": [
    {
      "planned": "Use flat directory layout",
      "actual": "Used nested .ralph/ hierarchy",
      "reason": "Better isolation of orchestrator files"
    }
  ],
  "bugs_encountered": [
    {
      "description": "mkdir -p failed on NFS mount",
      "resolution": "Added retry logic with sleep",
      "resolved": true
    }
  ],
  "architectural_notes": [
    "Separated config from runtime state directories",
    "Used .ralph/ prefix to keep project root clean"
  ],
  "unfinished_business": [],
  "recommendations": [],
  "files_touched": [
    { "path": ".ralph/config/ralph.conf", "action": "created" },
    { "path": ".ralph/lib/context.sh", "action": "created" },
    { "path": ".gitignore", "action": "modified" }
  ],
  "plan_amendments": [],
  "tests_added": [
    {
      "file": "tests/context.bats",
      "test_names": ["context loads correctly", "context handles missing file"]
    }
  ],
  "constraints_discovered": [
    {
      "constraint": "NFS mounts have delayed mkdir visibility",
      "impact": "Must add sync or retry after directory creation"
    }
  ],
  "summary": "Created directory structure and initial config files.",
  "freeform": "Set up the full .ralph directory hierarchy. Key decision: nested layout under .ralph/ for isolation."
}
EOF

    # Create a minimal handoff with all-empty optional arrays
    cat > "$RALPH_DIR/handoffs/handoff-minimal.json" <<'EOF'
{
  "task_completed": {
    "task_id": "TASK-002",
    "summary": "Minimal task done.",
    "fully_complete": true
  },
  "deviations": [],
  "bugs_encountered": [],
  "architectural_notes": [],
  "unfinished_business": [],
  "recommendations": [],
  "files_touched": [],
  "plan_amendments": [],
  "tests_added": [],
  "constraints_discovered": [],
  "summary": "Minimal task done.",
  "freeform": "Nothing special."
}
EOF

    # log() stub
    log() { :; }
    export -f log

    # get_task_by_id() stub — looks up task from PLAN_FILE
    get_task_by_id() {
        local plan_file="$1"
        local task_id="$2"
        jq -c --arg id "$task_id" '.tasks[] | select(.id == $id)' "$plan_file"
    }
    export -f get_task_by_id

    # Source the module under test
    source "$PROJ_ROOT/.ralph/lib/progress-log.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# ===== format_progress_entry_md =====

@test "format_progress_entry_md produces markdown with all sections from a full handoff" {
    local handoff="$RALPH_DIR/handoffs/handoff-005.json"
    run format_progress_entry_md "$handoff" 5 "TASK-001"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"### TASK-001:"* ]]
    [[ "$output" == *"(Iteration 5)"* ]]
    [[ "$output" == *"**Summary:**"* ]]
    [[ "$output" == *"**Files changed"* ]]
    [[ "$output" == *"**Tests added:**"* ]]
    [[ "$output" == *"**Design decisions:**"* ]]
    [[ "$output" == *"**Constraints discovered:**"* ]]
    [[ "$output" == *"**Deviations:**"* ]]
    [[ "$output" == *"**Bugs encountered:**"* ]]
}

@test "format_progress_entry_md omits Deviations section when deviations array is empty" {
    # Create handoff with empty deviations
    local handoff="$TEST_DIR/handoff-no-dev.json"
    jq '.deviations = []' "$RALPH_DIR/handoffs/handoff-005.json" > "$handoff"

    run format_progress_entry_md "$handoff" 1 "TASK-001"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"**Deviations:**"* ]]
}

@test "format_progress_entry_md omits Constraints section when constraints array is empty" {
    local handoff="$TEST_DIR/handoff-no-constraints.json"
    jq '.constraints_discovered = []' "$RALPH_DIR/handoffs/handoff-005.json" > "$handoff"

    run format_progress_entry_md "$handoff" 1 "TASK-001"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"**Constraints discovered:**"* ]]
}

@test "format_progress_entry_md omits Tests added section when tests_added array is empty" {
    local handoff="$TEST_DIR/handoff-no-tests.json"
    jq '.tests_added = []' "$RALPH_DIR/handoffs/handoff-005.json" > "$handoff"

    run format_progress_entry_md "$handoff" 1 "TASK-001"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"**Tests added:**"* ]]
}

@test "format_progress_entry_md omits Bugs section when bugs_encountered array is empty" {
    local handoff="$TEST_DIR/handoff-no-bugs.json"
    jq '.bugs_encountered = []' "$RALPH_DIR/handoffs/handoff-005.json" > "$handoff"

    run format_progress_entry_md "$handoff" 1 "TASK-001"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"**Bugs encountered:**"* ]]
}

@test "format_progress_entry_md file count in header matches files_touched length" {
    local handoff="$RALPH_DIR/handoffs/handoff-005.json"
    run format_progress_entry_md "$handoff" 5 "TASK-001"
    [[ "$status" -eq 0 ]]
    # files_touched has 3 entries
    [[ "$output" == *"Files changed (3 files)"* ]]
}

@test "format_progress_entry_md handles handoff with all-empty optional arrays" {
    local handoff="$RALPH_DIR/handoffs/handoff-minimal.json"
    run format_progress_entry_md "$handoff" 2 "TASK-002"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"### TASK-002:"* ]]
    [[ "$output" == *"**Summary:**"* ]]
    # No optional sections should appear
    [[ "$output" != *"**Files changed"* ]]
    [[ "$output" != *"**Tests added:**"* ]]
    [[ "$output" != *"**Deviations:**"* ]]
    [[ "$output" != *"**Constraints discovered:**"* ]]
    [[ "$output" != *"**Bugs encountered:**"* ]]
}

# ===== format_progress_entry_json =====

@test "format_progress_entry_json output is valid JSON" {
    local handoff="$RALPH_DIR/handoffs/handoff-005.json"
    run format_progress_entry_json "$handoff" 5 "TASK-001"
    [[ "$status" -eq 0 ]]
    echo "$output" | jq . >/dev/null 2>&1
    [[ $? -eq 0 ]]
}

@test "format_progress_entry_json contains all required fields" {
    local handoff="$RALPH_DIR/handoffs/handoff-005.json"
    run format_progress_entry_json "$handoff" 5 "TASK-001"
    [[ "$status" -eq 0 ]]

    local json="$output"
    [[ "$(echo "$json" | jq -r '.task_id')" == "TASK-001" ]]
    [[ "$(echo "$json" | jq -r '.iteration')" == "5" ]]
    [[ -n "$(echo "$json" | jq -r '.timestamp')" ]]
    [[ -n "$(echo "$json" | jq -r '.summary')" ]]
    [[ -n "$(echo "$json" | jq -r '.title')" ]]
    [[ "$(echo "$json" | jq '.files_changed | length')" -eq 3 ]]
    [[ "$(echo "$json" | jq '.tests_added | length')" -eq 1 ]]
    [[ "$(echo "$json" | jq '.design_decisions | length')" -eq 2 ]]
    [[ "$(echo "$json" | jq '.constraints | length')" -eq 1 ]]
    [[ "$(echo "$json" | jq '.deviations | length')" -eq 1 ]]
    [[ "$(echo "$json" | jq '.bugs | length')" -eq 1 ]]
    [[ "$(echo "$json" | jq -r '.fully_complete')" == "true" ]]
}

@test "format_progress_entry_json extracts title from plan.json when get_task_by_id available" {
    local handoff="$RALPH_DIR/handoffs/handoff-005.json"
    run format_progress_entry_json "$handoff" 5 "TASK-001"
    [[ "$status" -eq 0 ]]
    local title
    title="$(echo "$output" | jq -r '.title')"
    [[ "$title" == "Create directory structure" ]]
}

@test "format_progress_entry_json falls back to task_id when plan lookup unavailable" {
    # Unset get_task_by_id so the fallback triggers
    unset -f get_task_by_id

    local handoff="$RALPH_DIR/handoffs/handoff-005.json"
    run format_progress_entry_json "$handoff" 5 "TASK-001"
    [[ "$status" -eq 0 ]]
    local title
    title="$(echo "$output" | jq -r '.title')"
    [[ "$title" == "TASK-001" ]]
}

@test "format_progress_entry_json handles handoff with empty arrays" {
    local handoff="$RALPH_DIR/handoffs/handoff-minimal.json"
    run format_progress_entry_json "$handoff" 2 "TASK-002"
    [[ "$status" -eq 0 ]]
    echo "$output" | jq . >/dev/null 2>&1
    [[ $? -eq 0 ]]
    [[ "$(echo "$output" | jq '.files_changed | length')" -eq 0 ]]
    [[ "$(echo "$output" | jq '.tests_added | length')" -eq 0 ]]
    [[ "$(echo "$output" | jq '.deviations | length')" -eq 0 ]]
    [[ "$(echo "$output" | jq '.constraints | length')" -eq 0 ]]
    [[ "$(echo "$output" | jq '.bugs | length')" -eq 0 ]]
}

# ===== append_progress_entry =====

@test "append_progress_entry creates both files when they don't exist" {
    # Ensure files don't exist
    rm -f "$RALPH_DIR/progress-log.md" "$RALPH_DIR/progress-log.json"

    local handoff="$RALPH_DIR/handoffs/handoff-005.json"
    run append_progress_entry "$handoff" 5 "TASK-001"
    [[ "$status" -eq 0 ]]
    [[ -f "$RALPH_DIR/progress-log.md" ]]
    [[ -f "$RALPH_DIR/progress-log.json" ]]
}

@test "append_progress_entry appends second entry without overwriting first" {
    local handoff1="$RALPH_DIR/handoffs/handoff-005.json"
    local handoff2="$RALPH_DIR/handoffs/handoff-minimal.json"

    append_progress_entry "$handoff1" 5 "TASK-001"
    append_progress_entry "$handoff2" 6 "TASK-002"

    # JSON should have 2 entries
    local count
    count="$(jq '.entries | length' "$RALPH_DIR/progress-log.json")"
    [[ "$count" -eq 2 ]]

    # Both task IDs should be present
    [[ "$(jq -r '.entries[0].task_id' "$RALPH_DIR/progress-log.json")" == "TASK-001" ]]
    [[ "$(jq -r '.entries[1].task_id' "$RALPH_DIR/progress-log.json")" == "TASK-002" ]]
}

@test "append_progress_entry updates plan_summary counts from plan.json" {
    local handoff="$RALPH_DIR/handoffs/handoff-005.json"
    append_progress_entry "$handoff" 5 "TASK-001"

    # plan.json has 1 done, 1 pending, 1 failed
    local total completed pending failed
    total="$(jq '.plan_summary.total_tasks' "$RALPH_DIR/progress-log.json")"
    completed="$(jq '.plan_summary.completed' "$RALPH_DIR/progress-log.json")"
    pending="$(jq '.plan_summary.pending' "$RALPH_DIR/progress-log.json")"
    failed="$(jq '.plan_summary.failed' "$RALPH_DIR/progress-log.json")"

    [[ "$total" -eq 3 ]]
    [[ "$completed" -eq 1 ]]
    [[ "$pending" -eq 1 ]]
    [[ "$failed" -eq 1 ]]
}

@test "append_progress_entry JSON validates with jq after multiple appends" {
    local handoff1="$RALPH_DIR/handoffs/handoff-005.json"
    local handoff2="$RALPH_DIR/handoffs/handoff-minimal.json"

    append_progress_entry "$handoff1" 5 "TASK-001"
    append_progress_entry "$handoff2" 6 "TASK-002"
    # Append again to TASK-001 with a different iteration
    append_progress_entry "$handoff1" 7 "TASK-001"

    # Validate entire JSON structure
    run jq . "$RALPH_DIR/progress-log.json"
    [[ "$status" -eq 0 ]]

    # Should have 3 entries (TASK-001 iter 5, TASK-002 iter 6, TASK-001 iter 7)
    local count
    count="$(jq '.entries | length' "$RALPH_DIR/progress-log.json")"
    [[ "$count" -eq 3 ]]
}

@test "append_progress_entry markdown contains summary table" {
    local handoff="$RALPH_DIR/handoffs/handoff-005.json"
    append_progress_entry "$handoff" 5 "TASK-001"

    local md_content
    md_content="$(cat "$RALPH_DIR/progress-log.md")"

    # Should contain the summary table headers
    [[ "$md_content" == *"| Task | Status | Summary |"* ]]
    # Should contain task IDs from plan.json
    [[ "$md_content" == *"TASK-001"* ]]
    [[ "$md_content" == *"TASK-002"* ]]
    [[ "$md_content" == *"TASK-003"* ]]
}

# ===== init_progress_log =====

@test "init_progress_log creates both files with correct initial structure" {
    rm -f "$RALPH_DIR/progress-log.md" "$RALPH_DIR/progress-log.json"

    init_progress_log

    [[ -f "$RALPH_DIR/progress-log.md" ]]
    [[ -f "$RALPH_DIR/progress-log.json" ]]

    # MD has header
    local md_content
    md_content="$(cat "$RALPH_DIR/progress-log.md")"
    [[ "$md_content" == *"# Ralph Deluxe"* ]]
    [[ "$md_content" == *"Progress Log"* ]]

    # JSON is valid and has expected structure
    run jq . "$RALPH_DIR/progress-log.json"
    [[ "$status" -eq 0 ]]
    [[ "$(jq -r '.generated_at' "$RALPH_DIR/progress-log.json")" != "null" ]]
}

@test "init_progress_log is idempotent — running twice doesn't duplicate content" {
    rm -f "$RALPH_DIR/progress-log.md" "$RALPH_DIR/progress-log.json"

    init_progress_log
    local md_size_1 json_size_1
    md_size_1="$(wc -c < "$RALPH_DIR/progress-log.md" | tr -d ' ')"
    json_size_1="$(wc -c < "$RALPH_DIR/progress-log.json" | tr -d ' ')"

    init_progress_log
    local md_size_2 json_size_2
    md_size_2="$(wc -c < "$RALPH_DIR/progress-log.md" | tr -d ' ')"
    json_size_2="$(wc -c < "$RALPH_DIR/progress-log.json" | tr -d ' ')"

    [[ "$md_size_1" -eq "$md_size_2" ]]
    [[ "$json_size_1" -eq "$json_size_2" ]]
}

@test "init_progress_log JSON has empty entries array and zero-count summary" {
    rm -f "$RALPH_DIR/progress-log.md" "$RALPH_DIR/progress-log.json"

    init_progress_log

    local entries_count
    entries_count="$(jq '.entries | length' "$RALPH_DIR/progress-log.json")"
    [[ "$entries_count" -eq 0 ]]

    local total
    total="$(jq '.plan_summary.total_tasks' "$RALPH_DIR/progress-log.json")"
    [[ "$total" -eq 0 ]]

    local completed
    completed="$(jq '.plan_summary.completed' "$RALPH_DIR/progress-log.json")"
    [[ "$completed" -eq 0 ]]
}
