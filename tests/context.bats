#!/usr/bin/env bats

# Scope: unit tests for context token estimation and budget-based prompt truncation.
# Fixture notes: each test uses an isolated temp workspace with copied fixtures,
# synthetic skills markdown files, and handoffs under TEST_DIR.


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

@test "truncate_to_budget truncates unstructured content with metadata" {
    # Budget of 5 tokens = 20 chars max
    local long_text="This is a much longer text that will exceed the budget we set"
    run truncate_to_budget "$long_text" 5
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"This is a much longe"* ]]
    [[ "$output" == *"[[TRUNCATION_METADATA]]"* ]]
    [[ "$output" == *'"truncated_sections":["unstructured"]'* ]]
}

@test "truncate_to_budget preserves high-priority task headers in sectioned prompt" {
    local sectioned
    sectioned=$(cat <<'EOF'
## Current Task
ID: TASK-123
Title: Preserve header

Description:
Very important details.

Acceptance Criteria:
- Keep header

## Failure Context
Validation failures happened in parser.

## Retrieved Memory
### Constraints
- Constraint A

### Decisions
- Decision A

## Previous Handoff
Narrative narrative narrative narrative narrative narrative narrative narrative narrative narrative narrative narrative narrative.

## Skills
Skill details repeated. Skill details repeated. Skill details repeated. Skill details repeated.

## Output Instructions
Output details repeated. Output details repeated. Output details repeated. Output details repeated.
EOF
)

    run truncate_to_budget "$sectioned" 35
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"## Current Task"* ]]
    [[ "$output" == *"ID: TASK-123"* ]]
    [[ "$output" == *"Acceptance Criteria:"* ]]
}

@test "truncate_to_budget trims low-priority sections first and emits metadata" {
    local sectioned
    sectioned=$(cat <<'EOF'
## Current Task
ID: TASK-777
Title: Budget priority behavior

Description:
Critical description.

Acceptance Criteria:
- Keep me

## Failure Context
Important failure context should survive.

## Retrieved Memory
### Constraints
- Constraint one

### Decisions
- Decision one

## Previous Handoff
NARRATIVE NARRATIVE NARRATIVE NARRATIVE NARRATIVE NARRATIVE NARRATIVE NARRATIVE NARRATIVE NARRATIVE NARRATIVE NARRATIVE NARRATIVE NARRATIVE NARRATIVE NARRATIVE.

## Skills
SKILL SKILL SKILL SKILL SKILL SKILL SKILL SKILL SKILL SKILL SKILL SKILL SKILL SKILL SKILL SKILL.

## Output Instructions
OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT.
EOF
)

    run truncate_to_budget "$sectioned" 55
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"[[TRUNCATION_METADATA]]"* ]]
    [[ "$output" == *'"truncated_sections"'* ]]
    # Low-priority sections should be listed before higher-priority memory/failure sections.
    local skills_pos output_pos handoff_pos
    skills_pos=$(echo "$output" | grep -n '"Skills"' | head -1 | cut -d: -f1)
    output_pos=$(echo "$output" | grep -n '"Output Instructions"' | head -1 | cut -d: -f1)
    handoff_pos=$(echo "$output" | grep -n '"Previous Handoff"' | head -1 | cut -d: -f1)
    [[ -n "$skills_pos" ]]
    [[ -n "$output_pos" ]]
    [[ -z "$handoff_pos" || "$skills_pos" -le "$handoff_pos" ]]
}


@test "build_coding_prompt_v2 tolerates missing acceptance_criteria" {
    local task_json='{"id":"TASK-NA","title":"No AC","description":"No acceptance criteria field"}'
    run build_coding_prompt_v2 "$task_json" "handoff-only" "" ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"## Current Task"* ]]
    [[ "$output" == *"Acceptance Criteria:"* ]]
}

@test "build_coding_prompt_v2 falls back to coding-prompt.md when footer template is absent" {
    mkdir -p "$TEST_DIR/.ralph/templates"
    cat > "$TEST_DIR/.ralph/templates/coding-prompt.md" <<'EOF'
## When You're Done
Template fallback works.
EOF

    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task.json")

    local old_pwd
    old_pwd=$(pwd)
    cd "$TEST_DIR"
    run build_coding_prompt_v2 "$task_json" "handoff-only" "" ""
    cd "$old_pwd"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Template fallback works."* ]]
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

# --- get_prev_handoff_for_mode ---

@test "get_prev_handoff_for_mode extracts freeform from latest handoff in handoff-only mode" {
    run get_prev_handoff_for_mode "$TEST_DIR/handoffs" "handoff-only"
    [[ "$status" -eq 0 ]]
    # Should contain the freeform narrative text from sample-handoff.json
    [[ "$output" == *"git operations module"* ]]
    [[ "$output" == *"rev-parse HEAD"* ]]
}

@test "get_prev_handoff_for_mode returns empty when no handoffs exist" {
    local empty_dir
    empty_dir=$(mktemp -d)
    run get_prev_handoff_for_mode "$empty_dir" "handoff-only"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
    rm -rf "$empty_dir"
}

@test "get_prev_handoff_for_mode picks latest handoff by number" {
    cp "$TEST_DIR/fixtures/sample-handoff-002.json" "$TEST_DIR/handoffs/handoff-004.json"
    run get_prev_handoff_for_mode "$TEST_DIR/handoffs" "handoff-only"
    [[ "$status" -eq 0 ]]
    # Should pick handoff-004 freeform (mentions jq amendment)
    [[ "$output" == *"jq amendment insertion"* ]]
}

@test "get_prev_handoff_for_mode returns freeform plus structured context in handoff-plus-index mode" {
    run get_prev_handoff_for_mode "$TEST_DIR/handoffs" "handoff-plus-index"
    [[ "$status" -eq 0 ]]
    # Should contain the freeform narrative
    [[ "$output" == *"git operations module"* ]]
    # Should also contain the structured context header
    [[ "$output" == *"Structured context from previous iteration"* ]]
    # Should contain task ID from structured L2
    [[ "$output" == *"TASK-003"* ]]
}


@test "get_prev_handoff_for_mode falls back to handoff-only on unknown mode" {
    run get_prev_handoff_for_mode "$TEST_DIR/handoffs" "unexpected-mode"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"git operations module"* ]]
    [[ "$output" != *"Structured context from previous iteration"* ]]
}

@test "get_prev_handoff_for_mode defaults to handoff-only when mode not specified" {
    run get_prev_handoff_for_mode "$TEST_DIR/handoffs"
    [[ "$status" -eq 0 ]]
    # Should return just freeform (handoff-only behavior)
    [[ "$output" == *"git operations module"* ]]
    # Should NOT contain the structured context header
    [[ "$output" != *"Structured context from previous iteration"* ]]
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
    [[ "$output" == *"## Skills"* ]]
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

# --- build_coding_prompt_v2 ---

@test "build_coding_prompt_v2 assembles task and handoff sections in handoff-only mode" {
    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task.json")

    # Need to cd so the function can find .ralph/templates/
    mkdir -p "$TEST_DIR/.ralph/handoffs"
    mkdir -p "$TEST_DIR/.ralph/templates"
    cp "$TEST_DIR/handoffs/handoff-003.json" "$TEST_DIR/.ralph/handoffs/"
    cd "$TEST_DIR"

    run build_coding_prompt_v2 "$task_json" "handoff-only" "" ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"## Current Task"* ]]
    [[ "$output" == *"TASK-005"* ]]
    [[ "$output" == *"## Previous Handoff"* ]]
    [[ "$output" == *"git operations module"* ]]
    [[ "$output" == *"## Output Instructions"* ]]
}

@test "build_coding_prompt_v2 shows first-iteration message when no handoffs exist" {
    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task.json")

    mkdir -p "$TEST_DIR/.ralph/handoffs"
    mkdir -p "$TEST_DIR/.ralph/templates"
    cd "$TEST_DIR"

    # Empty handoffs dir — remove any handoffs
    rm -f "$TEST_DIR/.ralph/handoffs/"*.json

    run build_coding_prompt_v2 "$task_json" "handoff-only" "" ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"## Previous Handoff"* ]]
    [[ "$output" == *"first iteration"* ]]
}

@test "build_coding_prompt_v2 includes failure context when retrying" {
    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task.json")

    mkdir -p "$TEST_DIR/.ralph/handoffs"
    mkdir -p "$TEST_DIR/.ralph/templates"
    cp "$TEST_DIR/handoffs/handoff-003.json" "$TEST_DIR/.ralph/handoffs/"
    cd "$TEST_DIR"

    run build_coding_prompt_v2 "$task_json" "handoff-only" "" "Tests failed: 3 errors in validation.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"## Failure Context"* ]]
    [[ "$output" == *"Tests failed: 3 errors"* ]]
}

@test "build_coding_prompt_v2 includes skills when provided" {
    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task.json")

    mkdir -p "$TEST_DIR/.ralph/handoffs"
    mkdir -p "$TEST_DIR/.ralph/templates"
    cp "$TEST_DIR/handoffs/handoff-003.json" "$TEST_DIR/.ralph/handoffs/"
    cd "$TEST_DIR"

    run build_coding_prompt_v2 "$task_json" "handoff-only" "# Use set -euo pipefail" ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"## Skills"* ]]
    [[ "$output" == *"set -euo pipefail"* ]]
}

@test "build_coding_prompt_v2 does NOT include knowledge index pointer in handoff-only mode" {
    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task.json")

    mkdir -p "$TEST_DIR/.ralph/handoffs"
    mkdir -p "$TEST_DIR/.ralph/templates"
    cp "$TEST_DIR/handoffs/handoff-003.json" "$TEST_DIR/.ralph/handoffs/"
    # Create the knowledge index file
    echo "# Knowledge Index" > "$TEST_DIR/.ralph/knowledge-index.md"
    cd "$TEST_DIR"

    run build_coding_prompt_v2 "$task_json" "handoff-only" "" ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"## Retrieved Memory"* ]]
    [[ "$output" != *"knowledge-index.md"* ]]
}

@test "build_coding_prompt_v2 includes knowledge index pointer in handoff-plus-index mode" {
    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task.json")

    mkdir -p "$TEST_DIR/.ralph/handoffs"
    mkdir -p "$TEST_DIR/.ralph/templates"
    cp "$TEST_DIR/handoffs/handoff-003.json" "$TEST_DIR/.ralph/handoffs/"
    # Create the knowledge index file
    echo "# Knowledge Index" > "$TEST_DIR/.ralph/knowledge-index.md"
    cd "$TEST_DIR"

    run build_coding_prompt_v2 "$task_json" "handoff-plus-index" "" ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"## Retrieved Memory"* ]]
    [[ "$output" == *"knowledge-index.md"* ]]
}

@test "build_coding_prompt_v2 includes retrieved project memory lines relevant to task" {
    local task_json
    task_json='{
      "id": "TASK-321",
      "title": "Fix jq parsing bug in context assembly",
      "description": "Adjust parser behavior for jq and bash orchestration scripts.",
      "libraries": ["jq", "bash"],
      "acceptance_criteria": ["Relevant memory should be included"]
    }'

    mkdir -p "$TEST_DIR/.ralph/handoffs"
    mkdir -p "$TEST_DIR/.ralph/templates"
    cp "$TEST_DIR/handoffs/handoff-003.json" "$TEST_DIR/.ralph/handoffs/"
    cat > "$TEST_DIR/.ralph/knowledge-index.md" <<'EOF'
# Knowledge Index

## Constraints
- jq output must stay JSON-safe for TASK-321 migration logic.
- Keep bash compatibility with existing shellcheck rules.

## Architectural Decisions
- Use jq streaming mode when handling large orchestration payloads.

## Gotchas
- Some regex escapes in awk break jq filter extraction.
EOF
    cd "$TEST_DIR"

    run build_coding_prompt_v2 "$task_json" "handoff-plus-index" "" ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"## Retrieved Project Memory"* ]]
    [[ "$output" == *"TASK-321 migration logic"* ]]
    [[ "$output" == *"jq streaming mode"* ]]
}

@test "retrieve_relevant_knowledge truncates output to max lines" {
    local task_json
    task_json='{
      "id": "TASK-777",
      "title": "Harden parser",
      "description": "Improve parser reliability for orchestration runtime",
      "libraries": ["jq"]
    }'

    mkdir -p "$TEST_DIR/.ralph"
    {
        echo "# Knowledge Index"
        echo ""
        echo "## Constraints"
        for i in $(seq 1 20); do
            echo "- TASK-777 constraint line $i about jq parser behavior"
        done
    } > "$TEST_DIR/.ralph/knowledge-index.md"

    run retrieve_relevant_knowledge "$task_json" "$TEST_DIR/.ralph/knowledge-index.md" 8
    [[ "$status" -eq 0 ]]
    local line_count
    line_count=$(echo "$output" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')
    [[ "$line_count" -eq 8 ]]
}

@test "build_coding_prompt_v2 omits retrieved project memory when knowledge index is missing" {
    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task.json")

    mkdir -p "$TEST_DIR/.ralph/handoffs"
    mkdir -p "$TEST_DIR/.ralph/templates"
    cp "$TEST_DIR/handoffs/handoff-003.json" "$TEST_DIR/.ralph/handoffs/"
    cd "$TEST_DIR"

    run build_coding_prompt_v2 "$task_json" "handoff-plus-index" "" ""
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"## Retrieved Project Memory"* ]]
}

@test "build_coding_prompt_v2 omits knowledge index pointer when file missing in handoff-plus-index mode" {
    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task.json")

    mkdir -p "$TEST_DIR/.ralph/handoffs"
    mkdir -p "$TEST_DIR/.ralph/templates"
    cp "$TEST_DIR/handoffs/handoff-003.json" "$TEST_DIR/.ralph/handoffs/"
    cd "$TEST_DIR"

    # No knowledge-index.md file
    run build_coding_prompt_v2 "$task_json" "handoff-plus-index" "" ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"## Retrieved Memory"* ]]
    [[ "$output" != *"knowledge-index.md"* ]]
}

@test "build_coding_prompt_v2 includes retrieved memory constraints and decisions from handoff" {
    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task.json")

    mkdir -p "$TEST_DIR/.ralph/handoffs"
    mkdir -p "$TEST_DIR/.ralph/templates"
    cp "$TEST_DIR/handoffs/handoff-003.json" "$TEST_DIR/.ralph/handoffs/"
    cd "$TEST_DIR"

    run build_coding_prompt_v2 "$task_json" "handoff-plus-index" "" ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"### Constraints"* ]]
    [[ "$output" == *"git clean -fd removes files matching .gitignore patterns"* ]]
    [[ "$output" == *"### Decisions"* ]]
}

@test "build_coding_prompt_v2 adds structured L2 in Previous Handoff for handoff-plus-index mode" {
    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task.json")

    mkdir -p "$TEST_DIR/.ralph/handoffs"
    mkdir -p "$TEST_DIR/.ralph/templates"
    cp "$TEST_DIR/handoffs/handoff-003.json" "$TEST_DIR/.ralph/handoffs/"
    cd "$TEST_DIR"

    run build_coding_prompt_v2 "$task_json" "handoff-plus-index" "" ""
    [[ "$status" -eq 0 ]]
    # In handoff-plus-index mode, the Previous Handoff section should include
    # structured L2 data from get_prev_handoff_for_mode (not just freeform)
    [[ "$output" == *"Structured context from previous iteration"* ]]
    [[ "$output" == *"TASK-003"* ]]
}

@test "build_coding_prompt_v2 does NOT add structured L2 in Previous Handoff for handoff-only mode" {
    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task.json")

    mkdir -p "$TEST_DIR/.ralph/handoffs"
    mkdir -p "$TEST_DIR/.ralph/templates"
    cp "$TEST_DIR/handoffs/handoff-003.json" "$TEST_DIR/.ralph/handoffs/"
    cd "$TEST_DIR"

    run build_coding_prompt_v2 "$task_json" "handoff-only" "" ""
    [[ "$status" -eq 0 ]]
    # In handoff-only mode, no structured L2 in Previous Handoff section
    [[ "$output" != *"Structured context from previous iteration"* ]]
}

@test "build_coding_prompt_v2 priority order: task > failure > handoff > retrieved > knowledge > skills > output" {
    local task_json
    task_json=$(cat "$TEST_DIR/fixtures/sample-task.json")

    mkdir -p "$TEST_DIR/.ralph/handoffs"
    mkdir -p "$TEST_DIR/.ralph/templates"
    cp "$TEST_DIR/handoffs/handoff-003.json" "$TEST_DIR/.ralph/handoffs/"
    cat > "$TEST_DIR/.ralph/knowledge-index.md" <<'EOF'
# Knowledge Index

## Constraints
- TASK-005 context assembly must preserve ordering in prompts.
EOF
    cd "$TEST_DIR"

    run build_coding_prompt_v2 "$task_json" "handoff-plus-index" "skills content" "failure info"
    [[ "$status" -eq 0 ]]

    local task_pos failure_pos retrieved_memory_pos handoff_pos retrieved_pos knowledge_pos skills_pos output_pos
    task_pos=$(echo "$output" | grep -n "## Current Task" | head -1 | cut -d: -f1)
    failure_pos=$(echo "$output" | grep -n "## Failure Context" | head -1 | cut -d: -f1)
    retrieved_memory_pos=$(echo "$output" | grep -n "## Retrieved Memory" | head -1 | cut -d: -f1)
    handoff_pos=$(echo "$output" | grep -n "## Previous Handoff" | head -1 | cut -d: -f1)
    retrieved_pos=$(echo "$output" | grep -n "## Retrieved Project Memory" | head -1 | cut -d: -f1)
    knowledge_pos=$(echo "$output" | grep -n "## Accumulated Knowledge" | head -1 | cut -d: -f1)
    skills_pos=$(echo "$output" | grep -n "## Skills" | head -1 | cut -d: -f1)
    output_pos=$(echo "$output" | grep -n "## Output Instructions" | head -1 | cut -d: -f1)

    [[ "$task_pos" -lt "$failure_pos" ]]
    [[ "$failure_pos" -lt "$retrieved_memory_pos" ]]
    [[ "$retrieved_memory_pos" -lt "$handoff_pos" ]]
    [[ "$handoff_pos" -lt "$retrieved_pos" ]]
    [[ "$retrieved_pos" -lt "$knowledge_pos" ]]
    [[ "$knowledge_pos" -lt "$skills_pos" ]]
    [[ "$skills_pos" -lt "$output_pos" ]]
}

@test "truncate_to_budget handles Retrieved Project Memory and Accumulated Knowledge sections" {
    local sectioned
    sectioned=$(cat <<'EOF'
## Current Task
ID: TASK-123
Title: Test truncation

Description:
Details.

Acceptance Criteria:
- Pass

## Failure Context
No failure context.

## Retrieved Memory
### Constraints
- Constraint A

### Decisions
- Decision A

## Previous Handoff
Narrative text. Narrative text. Narrative text.

## Retrieved Project Memory
- [K-constraint-timeout] Shell MUST NOT exceed 30s [source: iter 7]
- [K-decision-jq-streaming] Use jq streaming mode [source: iter 6]

## Accumulated Knowledge
A knowledge index is at .ralph/knowledge-index.md.

## Skills
Skill details. Skill details. Skill details. Skill details.

## Output Instructions
Output details. Output details. Output details. Output details.
EOF
)

    # Budget large enough to keep everything
    run truncate_to_budget "$sectioned" 500
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"## Retrieved Project Memory"* ]]
    [[ "$output" == *"K-constraint-timeout"* ]]
    [[ "$output" == *"## Accumulated Knowledge"* ]]
}

@test "truncate_to_budget trims Accumulated Knowledge before Skills under pressure" {
    local sectioned
    sectioned=$(cat <<'EOF'
## Current Task
ID: TASK-789
Title: Budget test

Description:
Desc.

Acceptance Criteria:
- Pass

## Failure Context
No failure context.

## Retrieved Memory
### Constraints
- C

## Previous Handoff
Short narrative.

## Retrieved Project Memory
Important retrieved knowledge line.

## Accumulated Knowledge
A knowledge index is at .ralph/knowledge-index.md. Consult it if you need project history beyond the handoff above. Extra padding to make this section large enough to matter in truncation testing.

## Skills
SKILL SKILL SKILL SKILL SKILL SKILL SKILL SKILL SKILL SKILL SKILL SKILL SKILL SKILL SKILL SKILL.

## Output Instructions
OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT OUT.
EOF
)

    # Set a budget tight enough to trigger truncation of Accumulated Knowledge
    # but large enough to keep Retrieved Project Memory intact.
    # Content is ~685 chars with headers; Accumulated Knowledge body is ~175 chars.
    # Budget of 130 tokens (520 chars) forces Accumulated Knowledge removal only.
    run truncate_to_budget "$sectioned" 130
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"[[TRUNCATION_METADATA]]"* ]]
    [[ "$output" == *'"Accumulated Knowledge"'* ]]
    # Retrieved Project Memory should still be present (higher priority than Accumulated Knowledge)
    [[ "$output" == *"Important retrieved knowledge line"* ]]
}
