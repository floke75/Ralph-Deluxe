#!/usr/bin/env bats

# tests/context.bats — Tests for .ralph/lib/context.sh

PROJ_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    # Create a temp dir for each test
    TEST_DIR=$(mktemp -d)
    export TEST_DIR

    # Copy fixtures
    cp -r "$PROJ_ROOT/tests/fixtures" "$TEST_DIR/fixtures"

    # Create mock skills directory
    mkdir -p "$TEST_DIR/skills"
    echo "# Bash Conventions" > "$TEST_DIR/skills/bash-conventions.md"
    echo "Use set -euo pipefail" >> "$TEST_DIR/skills/bash-conventions.md"
    echo "" >> "$TEST_DIR/skills/bash-conventions.md"
    echo "# jq Patterns" > "$TEST_DIR/skills/jq-patterns.md"
    echo "Use composable filters" >> "$TEST_DIR/skills/jq-patterns.md"

    # Create mock handoffs directory with a handoff
    mkdir -p "$TEST_DIR/handoffs"
    cp "$TEST_DIR/fixtures/sample-handoff.json" "$TEST_DIR/handoffs/handoff-003.json"

    # Source the module under test
    source "$PROJ_ROOT/.ralph/lib/context.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# --- estimate_tokens ---

@test "estimate_tokens returns chars/4 for a known string" {
    # 40 chars -> 10 tokens
    local text="This is exactly a forty character text!!"
    run estimate_tokens "$text"
    [[ "$status" -eq 0 ]]
    [[ "$output" -eq 10 ]]
}

@test "estimate_tokens returns 0 for empty string" {
    run estimate_tokens ""
    [[ "$status" -eq 0 ]]
    [[ "$output" -eq 0 ]]
}

@test "estimate_tokens accuracy within 20% for multi-line content" {
    # 200 chars -> should be ~50 tokens
    local text
    text=$(printf '%0.s.' {1..200})
    run estimate_tokens "$text"
    [[ "$status" -eq 0 ]]
    [[ "$output" -eq 50 ]]
}

# --- truncate_to_budget ---

@test "truncate_to_budget returns content unchanged when under budget" {
    local short_text="This is a short text."
    run truncate_to_budget "$short_text" 100
    [[ "$status" -eq 0 ]]
    [[ "$output" == "$short_text" ]]
}

@test "truncate_to_budget truncates when over budget" {
    # Budget of 5 tokens = 20 chars max
    local long_text="This is a much longer text that will exceed the budget we set"
    run truncate_to_budget "$long_text" 5
    [[ "$status" -eq 0 ]]
    # Output should start with the first 20 chars
    [[ "$output" == *"This is a much longe"* ]]
    # Output should contain truncation notice
    [[ "$output" == *"CONTEXT TRUNCATED"* ]]
}

@test "truncate_to_budget includes char counts in notice" {
    local long_text
    long_text=$(printf '%0.s.' {1..100})
    run truncate_to_budget "$long_text" 10
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"100 chars exceeded 40 char budget"* ]]
}

# --- load_skills ---

@test "load_skills loads multiple skill files" {
    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task.json")
    run load_skills "$task_json" "$TEST_DIR/skills"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Bash Conventions"* ]]
    [[ "$output" == *"jq Patterns"* ]]
}

@test "load_skills handles missing skill file gracefully" {
    local task_json='{"skills": ["nonexistent-skill"]}'
    run load_skills "$task_json" "$TEST_DIR/skills"
    [[ "$status" -eq 0 ]]
    # Should just log a warning, not fail
}

@test "load_skills returns empty for task with no skills" {
    local task_json='{"skills": []}'
    run load_skills "$task_json" "$TEST_DIR/skills"
    [[ "$status" -eq 0 ]]
    # Output should be empty or just whitespace
    [[ -z "$(echo "$output" | tr -d '[:space:]')" ]]
}

@test "load_skills handles task with missing skills key" {
    local task_json='{"id": "TASK-001"}'
    run load_skills "$task_json" "$TEST_DIR/skills"
    [[ "$status" -eq 0 ]]
}

# --- get_prev_handoff_summary ---

@test "get_prev_handoff_summary extracts L2 from latest handoff" {
    run get_prev_handoff_summary "$TEST_DIR/handoffs"
    [[ "$status" -eq 0 ]]
    # Should contain the task ID
    [[ "$output" == *"TASK-003"* ]]
    # Should contain architectural notes
    [[ "$output" == *"decisions"* ]]
    # Should contain deviation info
    [[ "$output" == *"deviations"* ]]
}

@test "get_prev_handoff_summary returns empty when no handoffs exist" {
    local empty_dir
    empty_dir=$(mktemp -d)
    run get_prev_handoff_summary "$empty_dir"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
    rm -rf "$empty_dir"
}

@test "get_prev_handoff_summary picks latest handoff by number" {
    # Add a second handoff
    cp "$TEST_DIR/fixtures/sample-handoff-002.json" "$TEST_DIR/handoffs/handoff-004.json"
    run get_prev_handoff_summary "$TEST_DIR/handoffs"
    [[ "$status" -eq 0 ]]
    # Should pick handoff-004 (TASK-004) not handoff-003
    [[ "$output" == *"TASK-004"* ]]
}

# --- format_compacted_context ---

@test "format_compacted_context produces all markdown sections" {
    run format_compacted_context "$TEST_DIR/fixtures/sample-compacted-context.json"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"### Project State"* ]]
    [[ "$output" == *"### Completed Work"* ]]
    [[ "$output" == *"### Active Constraints (DO NOT VIOLATE)"* ]]
    [[ "$output" == *"### Architecture Decisions (Follow These)"* ]]
    [[ "$output" == *"### Library Reference"* ]]
}

@test "format_compacted_context includes project summary text" {
    run format_compacted_context "$TEST_DIR/fixtures/sample-compacted-context.json"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Ralph Deluxe orchestrator project"* ]]
}

@test "format_compacted_context includes completed work items" {
    run format_compacted_context "$TEST_DIR/fixtures/sample-compacted-context.json"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"- Phase 1: Directory structure"* ]]
    [[ "$output" == *"- Phase 3: Git checkpoint"* ]]
}

@test "format_compacted_context includes library docs when present" {
    run format_compacted_context "$TEST_DIR/fixtures/sample-compacted-context.json"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"bats-core"* ]]
    [[ "$output" == *"@test blocks"* ]]
}

@test "format_compacted_context returns empty for missing file" {
    run format_compacted_context "/nonexistent/file.json"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

# --- build_coding_prompt ---

@test "build_coding_prompt assembles all sections with full context" {
    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task.json")
    local compacted="Compacted context content here."
    local prev_handoff="Previous iteration summary here."
    local skills="# Some skill content"

    run build_coding_prompt "$task_json" "$compacted" "$prev_handoff" "$skills"
    [[ "$status" -eq 0 ]]
    # Check all major sections present
    [[ "$output" == *"## Current Task"* ]]
    [[ "$output" == *"## Output Requirements"* ]]
    [[ "$output" == *"## Skills & Conventions"* ]]
    [[ "$output" == *"## Project Context (Compacted)"* ]]
    [[ "$output" == *"## Previous Iteration Summary"* ]]
}

@test "build_coding_prompt includes task details" {
    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task.json")
    run build_coding_prompt "$task_json" "" "" ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"TASK-005"* ]]
    [[ "$output" == *"Implement context assembly module"* ]]
    [[ "$output" == *"build_coding_prompt assembles all sections"* ]]
}

@test "build_coding_prompt shows defaults when optional context missing" {
    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task.json")
    run build_coding_prompt "$task_json"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"No compacted context available"* ]]
    [[ "$output" == *"No previous iteration"* ]]
    [[ "$output" == *"No specific skills loaded"* ]]
}

@test "build_coding_prompt preserves priority order: task first, then output instructions" {
    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task.json")
    run build_coding_prompt "$task_json" "compacted" "prev" "skills"
    [[ "$status" -eq 0 ]]

    # Task section should come before Output Requirements
    local task_pos output_pos skills_pos compacted_pos prev_pos
    task_pos=$(echo "$output" | grep -n "## Current Task" | head -1 | cut -d: -f1)
    output_pos=$(echo "$output" | grep -n "## Output Requirements" | head -1 | cut -d: -f1)
    skills_pos=$(echo "$output" | grep -n "## Skills" | head -1 | cut -d: -f1)
    compacted_pos=$(echo "$output" | grep -n "## Project Context" | head -1 | cut -d: -f1)
    prev_pos=$(echo "$output" | grep -n "## Previous Iteration" | head -1 | cut -d: -f1)

    # Priority order: task > output > skills > previous L2 > compacted context
    [[ "$task_pos" -lt "$output_pos" ]]
    [[ "$output_pos" -lt "$skills_pos" ]]
    [[ "$skills_pos" -lt "$prev_pos" ]]
    [[ "$prev_pos" -lt "$compacted_pos" ]]
}
