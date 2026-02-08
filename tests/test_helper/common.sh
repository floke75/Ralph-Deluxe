#!/usr/bin/env bash

# Scope: shared helper functions used across Ralph Deluxe bats suites.
# Fixture notes: common_setup/common_teardown manage TEST_DIR lifecycle and export
# default env vars expected by library modules under test.


PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Stub log function (no-op for tests)
log() {
    : # no-op
}
export -f log

# common_setup — Create temp dir, set default env vars
common_setup() {
    TEST_DIR="$(mktemp -d)"
    export TEST_DIR PROJ_ROOT

    # Default config vars used by various modules
    export RALPH_COMMIT_PREFIX="ralph"
    export RALPH_VALIDATION_STRATEGY="strict"
    export RALPH_VALIDATION_COMMANDS=("true")
    export RALPH_COMPACTION_THRESHOLD_BYTES=32000
    export RALPH_COMPACTION_INTERVAL=5
    export RALPH_CONTEXT_BUDGET_TOKENS=8000
    export RALPH_LOG_LEVEL="error"
    export RALPH_LOG_FILE=".ralph/logs/ralph.log"
}

# common_teardown — Clean up temp dir
common_teardown() {
    if [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}

# create_test_git_repo — Initialize a minimal git repo in TEST_DIR
create_test_git_repo() {
    cd "$TEST_DIR" || return 1
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add -A
    git commit --quiet -m "initial commit"
}

# create_sample_plan — Write a minimal plan.json with 3 tasks to a given path
# Args: $1 = output path (default: $TEST_DIR/plan.json)
create_sample_plan() {
    local output="${1:-$TEST_DIR/plan.json}"
    cat > "$output" <<'EOF'
{
  "project": "test-project",
  "branch": "main",
  "max_iterations": 10,
  "validation_strategy": "strict",
  "tasks": [
    {
      "id": "TASK-001",
      "title": "First task (done)",
      "description": "Already completed task.",
      "status": "done",
      "order": 1,
      "skills": ["bash-conventions"],
      "needs_docs": false,
      "libraries": [],
      "acceptance_criteria": ["Task is complete"],
      "depends_on": [],
      "max_turns": 15,
      "retry_count": 0,
      "max_retries": 2
    },
    {
      "id": "TASK-002",
      "title": "Second task (pending, depends on TASK-001)",
      "description": "Task with a satisfied dependency.",
      "status": "pending",
      "order": 2,
      "skills": ["bash-conventions", "jq-patterns"],
      "needs_docs": false,
      "libraries": [],
      "acceptance_criteria": ["Function works", "Tests pass"],
      "depends_on": ["TASK-001"],
      "max_turns": 20,
      "retry_count": 0,
      "max_retries": 2
    },
    {
      "id": "TASK-003",
      "title": "Third task (pending, no deps)",
      "description": "Independent pending task.",
      "status": "pending",
      "order": 3,
      "skills": [],
      "needs_docs": false,
      "libraries": [],
      "acceptance_criteria": ["Output is valid"],
      "depends_on": [],
      "max_turns": 15,
      "retry_count": 0,
      "max_retries": 2
    }
  ]
}
EOF
}

# create_sample_handoff — Write a sample handoff JSON to a given path
# Args: $1 = output path (default: $TEST_DIR/handoff.json)
#        $2 = task_id (default: TASK-002)
#        $3 = fully_complete (default: true)
create_sample_handoff() {
    local output="${1:-$TEST_DIR/handoff.json}"
    local task_id="${2:-TASK-002}"
    local fully_complete="${3:-true}"
    cat > "$output" <<EOF
{
  "task_completed": {
    "task_id": "${task_id}",
    "summary": "Implemented the requested feature. All tests pass.",
    "fully_complete": ${fully_complete}
  },
  "deviations": [],
  "bugs_encountered": [],
  "architectural_notes": ["Used standard patterns"],
  "unfinished_business": [],
  "recommendations": [],
  "files_touched": [
    {"path": "src/feature.sh", "action": "created"}
  ],
  "plan_amendments": [],
  "tests_added": [],
  "constraints_discovered": []
}
EOF
}

# create_ralph_dirs — Create the .ralph directory structure in TEST_DIR
create_ralph_dirs() {
    mkdir -p "$TEST_DIR/.ralph/config"
    mkdir -p "$TEST_DIR/.ralph/logs/validation"
    mkdir -p "$TEST_DIR/.ralph/handoffs"
    mkdir -p "$TEST_DIR/.ralph/context/compaction-history"
    mkdir -p "$TEST_DIR/.ralph/templates"
    mkdir -p "$TEST_DIR/.ralph/skills"
    mkdir -p "$TEST_DIR/.ralph/lib"
}

# create_test_state — Write an initial state.json
# Args: $1 = output path (default: $TEST_DIR/.ralph/state.json)
create_test_state() {
    local output="${1:-$TEST_DIR/.ralph/state.json}"
    cat > "$output" <<'EOF'
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
}
