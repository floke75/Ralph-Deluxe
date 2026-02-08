#!/usr/bin/env bats

# Scope: unit tests for task selection and plan mutation behavior in plan-ops.sh.
# Fixture notes: plan fixtures are written inline; RALPH_DIR and log() are stubbed
# before sourcing to satisfy module globals in a temp TEST_DIR workspace.


# Stub log() and RALPH_DIR since plan-ops.sh uses them
log() { :; }
RALPH_DIR=""

setup() {
    TEST_DIR="$(mktemp -d)"
    RALPH_DIR="$TEST_DIR/.ralph"
    mkdir -p "$RALPH_DIR/logs"

    # Source the module under test
    source "${BATS_TEST_DIRNAME}/../.ralph/lib/plan-ops.sh"

    # Create a test plan with dependencies
    cat > "$TEST_DIR/plan.json" <<'PLAN'
{
  "project": "test",
  "tasks": [
    {
      "id": "TASK-001",
      "title": "First task",
      "description": "Already done",
      "status": "done",
      "order": 1,
      "skills": [],
      "depends_on": []
    },
    {
      "id": "TASK-002",
      "title": "Second task",
      "description": "Depends on first",
      "status": "pending",
      "order": 2,
      "skills": [],
      "depends_on": ["TASK-001"]
    },
    {
      "id": "TASK-003",
      "title": "Third task",
      "description": "Depends on second",
      "status": "pending",
      "order": 3,
      "skills": [],
      "depends_on": ["TASK-002"]
    },
    {
      "id": "TASK-004",
      "title": "Fourth task",
      "description": "No deps but pending",
      "status": "pending",
      "order": 4,
      "skills": [],
      "depends_on": []
    }
  ]
}
PLAN
}

teardown() {
    rm -rf "$TEST_DIR"
}

# --- get_next_task ---

@test "get_next_task returns first pending task with satisfied deps" {
    run get_next_task "$TEST_DIR/plan.json"
    [ "$status" -eq 0 ]
    local task_id
    task_id="$(echo "$output" | jq -r '.id')"
    # TASK-002 depends on TASK-001 (done), so it qualifies
    # TASK-004 has no deps, so it also qualifies
    # Either TASK-002 or TASK-004 could be first depending on jq ordering;
    # jq preserves array order, so TASK-002 comes first
    [ "$task_id" = "TASK-002" ]
}

@test "get_next_task skips tasks with unmet dependencies" {
    # TASK-003 depends on TASK-002 which is pending - should not be returned
    run get_next_task "$TEST_DIR/plan.json"
    [ "$status" -eq 0 ]
    local task_id
    task_id="$(echo "$output" | jq -r '.id')"
    [ "$task_id" != "TASK-003" ]
}

@test "get_next_task returns empty when all tasks are done" {
    cat > "$TEST_DIR/alldone.json" <<'PLAN'
{
  "project": "test",
  "tasks": [
    { "id": "T1", "title": "Done", "description": "d", "status": "done", "depends_on": [] },
    { "id": "T2", "title": "Skipped", "description": "d", "status": "skipped", "depends_on": [] }
  ]
}
PLAN
    run get_next_task "$TEST_DIR/alldone.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- set_task_status ---

@test "set_task_status persists status change" {
    set_task_status "$TEST_DIR/plan.json" "TASK-002" "in_progress"
    local new_status
    new_status="$(jq -r '.tasks[] | select(.id == "TASK-002") | .status' "$TEST_DIR/plan.json")"
    [ "$new_status" = "in_progress" ]
}

@test "set_task_status does not affect other tasks" {
    set_task_status "$TEST_DIR/plan.json" "TASK-002" "done"
    local task1_status
    task1_status="$(jq -r '.tasks[] | select(.id == "TASK-001") | .status' "$TEST_DIR/plan.json")"
    [ "$task1_status" = "done" ]
    local task3_status
    task3_status="$(jq -r '.tasks[] | select(.id == "TASK-003") | .status' "$TEST_DIR/plan.json")"
    [ "$task3_status" = "pending" ]
}

# --- get_task_by_id ---

@test "get_task_by_id returns correct task" {
    run get_task_by_id "$TEST_DIR/plan.json" "TASK-003"
    [ "$status" -eq 0 ]
    local title
    title="$(echo "$output" | jq -r '.title')"
    [ "$title" = "Third task" ]
}

@test "get_task_by_id returns empty for nonexistent task" {
    run get_task_by_id "$TEST_DIR/plan.json" "TASK-999"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- apply_amendments: add ---

@test "apply_amendments add inserts a new task" {
    cat > "$TEST_DIR/handoff.json" <<'HANDOFF'
{
  "plan_amendments": [
    {
      "action": "add",
      "task": {
        "id": "TASK-005",
        "title": "New task",
        "description": "Added via amendment"
      },
      "after": "TASK-002",
      "reason": "discovered new requirement"
    }
  ]
}
HANDOFF
    apply_amendments "$TEST_DIR/plan.json" "$TEST_DIR/handoff.json"

    # Verify task was added
    local new_task_title
    new_task_title="$(jq -r '.tasks[] | select(.id == "TASK-005") | .title' "$TEST_DIR/plan.json")"
    [ "$new_task_title" = "New task" ]

    # Verify it was inserted after TASK-002
    local ids
    ids="$(jq -r '[.tasks[].id] | join(",")' "$TEST_DIR/plan.json")"
    [ "$ids" = "TASK-001,TASK-002,TASK-005,TASK-003,TASK-004" ]
}

# --- apply_amendments: modify ---

@test "apply_amendments modify updates task fields" {
    cat > "$TEST_DIR/handoff.json" <<'HANDOFF'
{
  "plan_amendments": [
    {
      "action": "modify",
      "task_id": "TASK-004",
      "changes": { "title": "Updated title", "max_turns": 30 },
      "reason": "need more turns"
    }
  ]
}
HANDOFF
    apply_amendments "$TEST_DIR/plan.json" "$TEST_DIR/handoff.json"

    local title
    title="$(jq -r '.tasks[] | select(.id == "TASK-004") | .title' "$TEST_DIR/plan.json")"
    [ "$title" = "Updated title" ]

    local turns
    turns="$(jq -r '.tasks[] | select(.id == "TASK-004") | .max_turns' "$TEST_DIR/plan.json")"
    [ "$turns" = "30" ]
}

# --- apply_amendments: remove ---

@test "apply_amendments remove deletes a task" {
    cat > "$TEST_DIR/handoff.json" <<'HANDOFF'
{
  "plan_amendments": [
    {
      "action": "remove",
      "task_id": "TASK-004",
      "reason": "no longer needed"
    }
  ]
}
HANDOFF
    apply_amendments "$TEST_DIR/plan.json" "$TEST_DIR/handoff.json"

    local count
    count="$(jq '[.tasks[] | select(.id == "TASK-004")] | length' "$TEST_DIR/plan.json")"
    [ "$count" -eq 0 ]
}

# --- apply_amendments: safety guardrails ---

@test "apply_amendments rejects removing done tasks" {
    cat > "$TEST_DIR/handoff.json" <<'HANDOFF'
{
  "plan_amendments": [
    {
      "action": "remove",
      "task_id": "TASK-001",
      "reason": "trying to remove done task"
    }
  ]
}
HANDOFF
    apply_amendments "$TEST_DIR/plan.json" "$TEST_DIR/handoff.json"

    # TASK-001 should still exist
    local count
    count="$(jq '[.tasks[] | select(.id == "TASK-001")] | length' "$TEST_DIR/plan.json")"
    [ "$count" -eq 1 ]
}

@test "apply_amendments rejects more than 3 amendments" {
    cat > "$TEST_DIR/handoff.json" <<'HANDOFF'
{
  "plan_amendments": [
    { "action": "modify", "task_id": "T1", "changes": {}, "reason": "a" },
    { "action": "modify", "task_id": "T2", "changes": {}, "reason": "b" },
    { "action": "modify", "task_id": "T3", "changes": {}, "reason": "c" },
    { "action": "modify", "task_id": "T4", "changes": {}, "reason": "d" }
  ]
}
HANDOFF
    run apply_amendments "$TEST_DIR/plan.json" "$TEST_DIR/handoff.json"
    [ "$status" -eq 1 ]
}

@test "apply_amendments rejects modifying current task status" {
    cat > "$TEST_DIR/handoff.json" <<'HANDOFF'
{
  "plan_amendments": [
    {
      "action": "modify",
      "task_id": "TASK-002",
      "changes": { "status": "done" },
      "reason": "trying to change own status"
    }
  ]
}
HANDOFF
    apply_amendments "$TEST_DIR/plan.json" "$TEST_DIR/handoff.json" "TASK-002"

    # Status should NOT have been changed
    local status_val
    status_val="$(jq -r '.tasks[] | select(.id == "TASK-002") | .status' "$TEST_DIR/plan.json")"
    [ "$status_val" = "pending" ]
}

@test "apply_amendments creates backup before mutation" {
    cat > "$TEST_DIR/handoff.json" <<'HANDOFF'
{
  "plan_amendments": [
    {
      "action": "remove",
      "task_id": "TASK-004",
      "reason": "test backup"
    }
  ]
}
HANDOFF
    apply_amendments "$TEST_DIR/plan.json" "$TEST_DIR/handoff.json"

    [ -f "$TEST_DIR/plan.json.bak" ]

    # Backup should contain the original TASK-004
    local bak_count
    bak_count="$(jq '[.tasks[] | select(.id == "TASK-004")] | length' "$TEST_DIR/plan.json.bak")"
    [ "$bak_count" -eq 1 ]
}

@test "apply_amendments logs to amendments.log" {
    cat > "$TEST_DIR/handoff.json" <<'HANDOFF'
{
  "plan_amendments": [
    {
      "action": "remove",
      "task_id": "TASK-004",
      "reason": "testing log output"
    }
  ]
}
HANDOFF
    apply_amendments "$TEST_DIR/plan.json" "$TEST_DIR/handoff.json"

    [ -f "$RALPH_DIR/logs/amendments.log" ]
    grep -q "REMOVE TASK-004" "$RALPH_DIR/logs/amendments.log"
    grep -q "testing log output" "$RALPH_DIR/logs/amendments.log"
}

# --- is_plan_complete ---

@test "is_plan_complete returns 0 when all tasks done or skipped" {
    cat > "$TEST_DIR/complete.json" <<'PLAN'
{
  "tasks": [
    { "id": "T1", "status": "done", "depends_on": [] },
    { "id": "T2", "status": "skipped", "depends_on": [] },
    { "id": "T3", "status": "done", "depends_on": [] }
  ]
}
PLAN
    run is_plan_complete "$TEST_DIR/complete.json"
    [ "$status" -eq 0 ]
}

@test "is_plan_complete returns 1 when tasks still pending" {
    run is_plan_complete "$TEST_DIR/plan.json"
    [ "$status" -eq 1 ]
}

# --- count_remaining_tasks ---

@test "count_remaining_tasks counts pending and failed tasks" {
    # Original plan has 3 pending tasks (TASK-002, TASK-003, TASK-004)
    run count_remaining_tasks "$TEST_DIR/plan.json"
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

@test "count_remaining_tasks returns 0 when all done" {
    cat > "$TEST_DIR/alldone.json" <<'PLAN'
{
  "tasks": [
    { "id": "T1", "status": "done", "depends_on": [] },
    { "id": "T2", "status": "done", "depends_on": [] }
  ]
}
PLAN
    run count_remaining_tasks "$TEST_DIR/alldone.json"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "count_remaining_tasks includes failed tasks" {
    cat > "$TEST_DIR/mixed.json" <<'PLAN'
{
  "tasks": [
    { "id": "T1", "status": "done", "depends_on": [] },
    { "id": "T2", "status": "failed", "depends_on": [] },
    { "id": "T3", "status": "pending", "depends_on": [] },
    { "id": "T4", "status": "skipped", "depends_on": [] }
  ]
}
PLAN
    run count_remaining_tasks "$TEST_DIR/mixed.json"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}
