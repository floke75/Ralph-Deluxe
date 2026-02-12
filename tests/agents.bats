#!/usr/bin/env bats

# agents.bats — Tests for the multi-agent orchestration framework
#
# Coverage:
#   - Agent iteration invocation (run_agent_iteration) with dry-run
#   - Agent output parsing (parse_agent_output)
#   - Context preparation input building (build_context_prep_input)
#   - Context post-processing input building (build_context_post_input)
#   - Directive handling (handle_prep_directives, handle_post_directives)
#   - Agent pass trigger evaluation (check_pass_trigger)
#   - Agent pass configuration loading (load_agent_passes_config)
#   - Full context prep flow in dry-run mode (run_context_prep)

load 'test_helper/common.sh'

setup() {
    common_setup
    create_ralph_dirs

    # Set required globals for agents.sh
    export RALPH_DIR="$TEST_DIR/.ralph"
    export STATE_FILE="$TEST_DIR/.ralph/state.json"
    export PROJECT_ROOT="$TEST_DIR"
    export DRY_RUN="true"
    export RALPH_SKIP_PERMISSIONS="true"
    export PLAN_FILE="plan.json"

    create_test_state
    create_sample_plan "$TEST_DIR/plan.json"

    # Create minimal template files
    echo "# Context Prep System Prompt" > "$TEST_DIR/.ralph/templates/context-prep-prompt.md"
    echo "# Context Post System Prompt" > "$TEST_DIR/.ralph/templates/context-post-prompt.md"
    echo "## When You're Done" > "$TEST_DIR/.ralph/templates/coding-prompt-footer.md"

    # Create config files
    cat > "$TEST_DIR/.ralph/config/agents.json" <<'EOF'
{
  "context_agent": {
    "model": null,
    "prep": {
      "max_turns": 10,
      "prompt_template": "context-prep-prompt.md",
      "schema": "context-prep-schema.json",
      "mcp_config": "mcp-context.json",
      "output_file": ".ralph/context/prepared-prompt.md"
    },
    "post": {
      "max_turns": 10,
      "prompt_template": "context-post-prompt.md",
      "schema": "context-post-schema.json",
      "mcp_config": "mcp-context.json"
    }
  },
  "passes": [
    {
      "name": "review",
      "enabled": true,
      "model": "haiku",
      "trigger": "on_success",
      "max_turns": 5,
      "prompt_template": "review-agent-prompt.md",
      "schema": "review-agent-schema.json",
      "mcp_config": "mcp-coding.json",
      "read_only": true
    },
    {
      "name": "docs",
      "enabled": false,
      "model": "haiku",
      "trigger": "periodic:3",
      "max_turns": 5,
      "prompt_template": "docs-agent-prompt.md",
      "schema": "docs-agent-schema.json",
      "mcp_config": "mcp-coding.json"
    }
  ]
}
EOF

    cat > "$TEST_DIR/.ralph/config/context-prep-schema.json" <<'EOF'
{
  "type": "object",
  "properties": {
    "action": { "type": "string", "enum": ["proceed", "skip", "request_human_review", "research"] },
    "reason": { "type": "string" },
    "stuck_detection": {
      "type": "object",
      "properties": { "is_stuck": { "type": "boolean" } },
      "required": ["is_stuck"]
    }
  },
  "required": ["action", "reason", "stuck_detection"]
}
EOF

    cat > "$TEST_DIR/.ralph/config/context-post-schema.json" <<'EOF'
{
  "type": "object",
  "properties": {
    "knowledge_updated": { "type": "boolean" },
    "recommended_action": { "type": "string" },
    "summary": { "type": "string" }
  },
  "required": ["knowledge_updated", "recommended_action", "summary"]
}
EOF

    cat > "$TEST_DIR/.ralph/config/mcp-context.json" <<'EOF'
{"mcpServers": {}}
EOF

    cat > "$TEST_DIR/.ralph/config/mcp-coding.json" <<'EOF'
{"mcpServers": {}}
EOF

    # Source the module under test
    source "$PROJ_ROOT/.ralph/lib/agents.sh"
}

teardown() {
    common_teardown
}

# ===== parse_agent_output tests =====

@test "parse_agent_output extracts valid JSON from response envelope" {
    local response='{"type":"result","result":"{\"action\":\"proceed\",\"reason\":\"all clear\"}"}'
    local output
    output="$(parse_agent_output "$response")"
    [[ "$(echo "$output" | jq -r '.action')" == "proceed" ]]
}

@test "parse_agent_output fails on empty result" {
    local response='{"type":"result","result":""}'
    run parse_agent_output "$response"
    [ "$status" -ne 0 ]
}

@test "parse_agent_output fails on missing result" {
    local response='{"type":"result"}'
    run parse_agent_output "$response"
    [ "$status" -ne 0 ]
}

@test "parse_agent_output fails on invalid inner JSON" {
    local response='{"type":"result","result":"not-json"}'
    run parse_agent_output "$response"
    [ "$status" -ne 0 ]
}

@test "parse_agent_output prefers structured_output over result" {
    local response='{"type":"result","structured_output":{"action":"skip","reason":"from structured"},"result":"{\"action\":\"proceed\",\"reason\":\"from result\"}"}'
    local output
    output="$(parse_agent_output "$response")"
    [[ "$(echo "$output" | jq -r '.action')" == "skip" ]]
}

@test "parse_agent_output extracts from structured_output when result is empty" {
    local response='{"type":"result","result":"","structured_output":{"action":"proceed","summary":"context ready"}}'
    local output
    output="$(parse_agent_output "$response")"
    [[ "$(echo "$output" | jq -r '.action')" == "proceed" ]]
}

@test "parse_agent_output falls back to result when structured_output is null" {
    local response='{"type":"result","structured_output":null,"result":"{\"action\":\"proceed\"}"}'
    local output
    output="$(parse_agent_output "$response")"
    [[ "$(echo "$output" | jq -r '.action')" == "proceed" ]]
}

# ===== build_context_prep_input tests =====

@test "build_context_prep_input includes task details" {
    local task_json='{"id":"TASK-002","title":"Test task","description":"Do the thing","acceptance_criteria":["It works"]}'
    local output
    output="$(build_context_prep_input "$task_json" 1 "agent-orchestrated")"
    [[ "$output" == *"TASK-002"* ]]
    [[ "$output" == *"Test task"* ]]
    [[ "$output" == *"Do the thing"* ]]
}

@test "build_context_prep_input includes iteration and mode" {
    local task_json='{"id":"TASK-002","title":"Test","description":"Test"}'
    local output
    output="$(build_context_prep_input "$task_json" 5 "agent-orchestrated")"
    [[ "$output" == *"Current iteration: 5"* ]]
    [[ "$output" == *"Mode: agent-orchestrated"* ]]
}

@test "build_context_prep_input includes handoff pointers when handoffs exist" {
    create_sample_handoff "$TEST_DIR/.ralph/handoffs/handoff-001.json" "TASK-001"
    local task_json='{"id":"TASK-002","title":"Test","description":"Test"}'
    local output
    output="$(build_context_prep_input "$task_json" 2 "agent-orchestrated")"
    [[ "$output" == *"handoff-001.json"* ]]
}

@test "build_context_prep_input indicates first iteration when no handoffs" {
    local task_json='{"id":"TASK-002","title":"Test","description":"Test"}'
    local output
    output="$(build_context_prep_input "$task_json" 1 "agent-orchestrated")"
    [[ "$output" == *"first iteration"* ]]
}

@test "build_context_prep_input includes knowledge index pointer when file exists" {
    echo "# Knowledge Index" > "$TEST_DIR/.ralph/knowledge-index.md"
    local task_json='{"id":"TASK-002","title":"Test","description":"Test"}'
    local output
    output="$(build_context_prep_input "$task_json" 2 "agent-orchestrated")"
    [[ "$output" == *"knowledge-index.md"* ]]
}

@test "build_context_prep_input includes failure context pointer when present" {
    mkdir -p "$TEST_DIR/.ralph/context"
    echo "Previous test failed" > "$TEST_DIR/.ralph/context/failure-context.md"
    local task_json='{"id":"TASK-002","title":"Test","description":"Test"}'
    local output
    output="$(build_context_prep_input "$task_json" 3 "agent-orchestrated")"
    [[ "$output" == *"failure-context.md"* ]]
}

@test "build_context_prep_input includes task metadata (retry count, skills, libraries)" {
    local task_json='{"id":"TASK-002","title":"Test","description":"Test","skills":["bash","jq"],"libraries":["lodash"],"needs_docs":true,"max_retries":3}'
    local output
    output="$(build_context_prep_input "$task_json" 1 "agent-orchestrated")"
    [[ "$output" == *"Skills: bash, jq"* ]]
    [[ "$output" == *"Libraries: lodash"* ]]
    [[ "$output" == *"Needs docs: true"* ]]
}

@test "build_context_prep_input specifies output file path" {
    local task_json='{"id":"TASK-002","title":"Test","description":"Test"}'
    local output
    output="$(build_context_prep_input "$task_json" 1 "agent-orchestrated")"
    [[ "$output" == *"prepared-prompt.md"* ]]
}

@test "build_context_prep_input forwards research requests from previous handoff" {
    cat > "$TEST_DIR/.ralph/handoffs/handoff-001.json" <<'EOF'
{
    "task_completed": {"task_id": "TASK-001", "summary": "done", "fully_complete": true},
    "deviations": [], "bugs_encountered": [], "architectural_notes": [],
    "unfinished_business": [], "recommendations": [],
    "files_touched": [], "plan_amendments": [], "tests_added": [],
    "constraints_discovered": [],
    "request_research": ["bats-core assertion syntax", "jq recursive descent"],
    "summary": "done",
    "freeform": "Need more info on bats assertions and jq patterns."
}
EOF
    local task_json='{"id":"TASK-002","title":"Test","description":"Test"}'
    local output
    output="$(build_context_prep_input "$task_json" 2 "agent-orchestrated")"
    [[ "$output" == *"Research Requests"* ]]
    [[ "$output" == *"bats-core assertion syntax"* ]]
    [[ "$output" == *"jq recursive descent"* ]]
    [[ "$output" == *"MUST investigate"* ]]
}

@test "build_context_prep_input forwards human review signal from previous handoff" {
    cat > "$TEST_DIR/.ralph/handoffs/handoff-001.json" <<'EOF'
{
    "task_completed": {"task_id": "TASK-001", "summary": "done", "fully_complete": true},
    "deviations": [], "bugs_encountered": [], "architectural_notes": [],
    "unfinished_business": [], "recommendations": [],
    "files_touched": [], "plan_amendments": [], "tests_added": [],
    "constraints_discovered": [],
    "request_human_review": {"needed": true, "reason": "Security-sensitive change"},
    "summary": "done",
    "freeform": "This needs human review."
}
EOF
    local task_json='{"id":"TASK-002","title":"Test","description":"Test"}'
    local output
    output="$(build_context_prep_input "$task_json" 2 "agent-orchestrated")"
    [[ "$output" == *"Human Review Signal"* ]]
    [[ "$output" == *"Security-sensitive change"* ]]
}

@test "build_context_prep_input forwards low confidence signal from previous handoff" {
    cat > "$TEST_DIR/.ralph/handoffs/handoff-001.json" <<'EOF'
{
    "task_completed": {"task_id": "TASK-001", "summary": "done", "fully_complete": true},
    "deviations": [], "bugs_encountered": [], "architectural_notes": [],
    "unfinished_business": [], "recommendations": [],
    "files_touched": [], "plan_amendments": [], "tests_added": [],
    "constraints_discovered": [],
    "confidence_level": "low",
    "summary": "done",
    "freeform": "Not confident about the approach."
}
EOF
    local task_json='{"id":"TASK-002","title":"Test","description":"Test"}'
    local output
    output="$(build_context_prep_input "$task_json" 2 "agent-orchestrated")"
    [[ "$output" == *"Coding Agent Confidence"* ]]
    [[ "$output" == *"low"* ]]
}

@test "build_context_prep_input does NOT include research section when no requests" {
    create_sample_handoff "$TEST_DIR/.ralph/handoffs/handoff-001.json" "TASK-001"
    local task_json='{"id":"TASK-002","title":"Test","description":"Test"}'
    local output
    output="$(build_context_prep_input "$task_json" 2 "agent-orchestrated")"
    [[ "$output" != *"Research Requests"* ]]
}

# ===== build_context_post_input tests =====

@test "build_context_post_input includes iteration and task details" {
    create_sample_handoff "$TEST_DIR/.ralph/handoffs/handoff-003.json" "TASK-002"
    local output
    output="$(build_context_post_input "$TEST_DIR/.ralph/handoffs/handoff-003.json" 3 "TASK-002" "passed")"
    [[ "$output" == *"Iteration: 3"* ]]
    [[ "$output" == *"Task ID: TASK-002"* ]]
    [[ "$output" == *"Validation result: passed"* ]]
}

@test "build_context_post_input includes handoff file pointer" {
    create_sample_handoff "$TEST_DIR/.ralph/handoffs/handoff-003.json" "TASK-002"
    local output
    output="$(build_context_post_input "$TEST_DIR/.ralph/handoffs/handoff-003.json" 3 "TASK-002" "passed")"
    [[ "$output" == *"handoff-003.json"* ]]
}

@test "build_context_post_input includes recent handoffs for pattern detection" {
    create_sample_handoff "$TEST_DIR/.ralph/handoffs/handoff-001.json" "TASK-001"
    create_sample_handoff "$TEST_DIR/.ralph/handoffs/handoff-002.json" "TASK-001"
    create_sample_handoff "$TEST_DIR/.ralph/handoffs/handoff-003.json" "TASK-002"
    local output
    output="$(build_context_post_input "$TEST_DIR/.ralph/handoffs/handoff-003.json" 3 "TASK-002" "passed")"
    [[ "$output" == *"pattern detection"* ]]
    [[ "$output" == *"handoff-001.json"* ]]
}

@test "build_context_post_input includes knowledge index status" {
    echo "# Knowledge Index" > "$TEST_DIR/.ralph/knowledge-index.md"
    create_sample_handoff "$TEST_DIR/.ralph/handoffs/handoff-001.json" "TASK-001"
    local output
    output="$(build_context_post_input "$TEST_DIR/.ralph/handoffs/handoff-001.json" 1 "TASK-001" "passed")"
    [[ "$output" == *"knowledge-index.md"* ]]
}

@test "build_context_post_input notes when knowledge index does not exist" {
    create_sample_handoff "$TEST_DIR/.ralph/handoffs/handoff-001.json" "TASK-001"
    local output
    output="$(build_context_post_input "$TEST_DIR/.ralph/handoffs/handoff-001.json" 1 "TASK-001" "passed")"
    [[ "$output" == *"does not exist yet"* ]]
}

# ===== handle_prep_directives tests =====

@test "handle_prep_directives returns proceed for proceed action" {
    local directive='{"action":"proceed","reason":"all clear","stuck_detection":{"is_stuck":false}}'
    local action
    action="$(handle_prep_directives "$directive")"
    [[ "$action" == "proceed" ]]
}

@test "handle_prep_directives returns skip for skip action" {
    local directive='{"action":"skip","reason":"task is blocked","stuck_detection":{"is_stuck":false}}'
    local action
    action="$(handle_prep_directives "$directive")"
    [[ "$action" == "skip" ]]
}

@test "handle_prep_directives returns request_human_review" {
    local directive='{"action":"request_human_review","reason":"complex situation","stuck_detection":{"is_stuck":false}}'
    local action
    action="$(handle_prep_directives "$directive")"
    [[ "$action" == "request_human_review" ]]
}

@test "handle_prep_directives returns research" {
    local directive='{"action":"research","reason":"need API docs","stuck_detection":{"is_stuck":false}}'
    local action
    action="$(handle_prep_directives "$directive")"
    [[ "$action" == "research" ]]
}

@test "handle_prep_directives defaults to proceed for unknown action" {
    local directive='{"action":"unknown","reason":"test","stuck_detection":{"is_stuck":false}}'
    local action
    action="$(handle_prep_directives "$directive")"
    [[ "$action" == "proceed" ]]
}

@test "handle_prep_directives handles stuck detection" {
    local directive='{"action":"skip","reason":"stuck","stuck_detection":{"is_stuck":true,"evidence":"same error 3 times","suggested_action":"skip task"}}'
    local action
    action="$(handle_prep_directives "$directive")"
    [[ "$action" == "skip" ]]
}

# ===== handle_post_directives tests =====

@test "handle_post_directives returns proceed by default" {
    local directive='{"knowledge_updated":true,"recommended_action":"proceed","summary":"index updated"}'
    local action
    action="$(handle_post_directives "$directive")"
    [[ "$action" == "proceed" ]]
}

@test "handle_post_directives returns skip_task" {
    local directive='{"knowledge_updated":false,"recommended_action":"skip_task","summary":"task infeasible"}'
    local action
    action="$(handle_post_directives "$directive")"
    [[ "$action" == "skip_task" ]]
}

@test "handle_post_directives handles failure pattern detection" {
    local directive='{"knowledge_updated":true,"recommended_action":"request_human_review","failure_pattern_detected":true,"failure_pattern":"same test fails 3 times","summary":"stuck"}'
    local action
    action="$(handle_post_directives "$directive")"
    [[ "$action" == "request_human_review" ]]
}

# ===== check_pass_trigger tests =====

@test "check_pass_trigger: always fires regardless of result" {
    run check_pass_trigger "always" "passed" 1
    [ "$status" -eq 0 ]
    run check_pass_trigger "always" "failed" 1
    [ "$status" -eq 0 ]
}

@test "check_pass_trigger: on_success fires only on passed" {
    run check_pass_trigger "on_success" "passed" 1
    [ "$status" -eq 0 ]
    run check_pass_trigger "on_success" "failed" 1
    [ "$status" -ne 0 ]
}

@test "check_pass_trigger: on_failure fires only on failed" {
    run check_pass_trigger "on_failure" "failed" 1
    [ "$status" -eq 0 ]
    run check_pass_trigger "on_failure" "passed" 1
    [ "$status" -ne 0 ]
}

@test "check_pass_trigger: periodic:3 fires on multiples of 3" {
    run check_pass_trigger "periodic:3" "passed" 3
    [ "$status" -eq 0 ]
    run check_pass_trigger "periodic:3" "passed" 6
    [ "$status" -eq 0 ]
    run check_pass_trigger "periodic:3" "passed" 4
    [ "$status" -ne 0 ]
}

@test "check_pass_trigger: unknown trigger returns failure" {
    run check_pass_trigger "unknown" "passed" 1
    [ "$status" -ne 0 ]
}

# ===== load_agent_passes_config tests =====

@test "load_agent_passes_config returns only enabled passes" {
    local config
    config="$(load_agent_passes_config)"
    local count
    count="$(echo "$config" | jq 'length')"
    # Only the "review" pass is enabled in test config
    [[ "$count" -eq 1 ]]
    [[ "$(echo "$config" | jq -r '.[0].name')" == "review" ]]
}

@test "load_agent_passes_config returns empty array when no config file" {
    rm "$TEST_DIR/.ralph/config/agents.json"
    local config
    config="$(load_agent_passes_config)"
    [[ "$(echo "$config" | jq 'length')" -eq 0 ]]
}

@test "load_agent_passes_config returns empty array when all passes disabled" {
    cat > "$TEST_DIR/.ralph/config/agents.json" <<'EOF'
{"context_agent": {}, "passes": [{"name": "review", "enabled": false}]}
EOF
    local config
    config="$(load_agent_passes_config)"
    [[ "$(echo "$config" | jq 'length')" -eq 0 ]]
}

# ===== run_context_prep dry-run tests =====

@test "run_context_prep dry-run creates prepared prompt file" {
    local task_json='{"id":"TASK-002","title":"Test","description":"Test","acceptance_criteria":["works"]}'
    local output
    output="$(run_context_prep "$task_json" 1 "agent-orchestrated")"
    [ -f "$TEST_DIR/.ralph/context/prepared-prompt.md" ]
}

@test "run_context_prep dry-run prepared prompt includes all canonical headers" {
    local task_json='{"id":"TASK-002","title":"Test","description":"Test","acceptance_criteria":["works"]}'
    run run_context_prep "$task_json" 1 "agent-orchestrated"
    [ "$status" -eq 0 ]

    local prompt_file="$TEST_DIR/.ralph/context/prepared-prompt.md"
    [ -f "$prompt_file" ]
    run validate_prepared_prompt_structure "$prompt_file"
    [ "$status" -eq 0 ]
}

@test "run_context_prep dry-run returns valid directive JSON" {
    local task_json='{"id":"TASK-002","title":"Test","description":"Test","acceptance_criteria":["works"]}'
    local output
    output="$(run_context_prep "$task_json" 1 "agent-orchestrated")"
    # Dry-run produces a stub directive
    [[ "$(echo "$output" | jq -r '.action')" == "proceed" ]]
}

@test "run_context_prep dry-run bypasses parse fallback when agent output is non-JSON" {
    run_agent_iteration() { echo '{"type":"result","result":"not-json"}'; }

    local task_json='{"id":"TASK-002","title":"Test","description":"Test","acceptance_criteria":["works"]}'
    local output
    output="$(run_context_prep "$task_json" 1 "agent-orchestrated")"

    [[ "$(echo "$output" | jq -r '.reason')" == "Dry run mode" ]]
    [ -f "$TEST_DIR/.ralph/context/prepared-prompt.md" ]
}

@test "run_context_prep fails when system prompt template is missing" {
    rm "$TEST_DIR/.ralph/templates/context-prep-prompt.md"
    local task_json='{"id":"TASK-002","title":"Test","description":"Test","acceptance_criteria":["works"]}'
    run run_context_prep "$task_json" 1 "agent-orchestrated"
    [ "$status" -ne 0 ]
}

@test "validate_prepared_prompt_structure fails when a required header is missing" {
    cat > "$TEST_DIR/.ralph/context/prepared-prompt.md" <<'EOF'
## Current Task
Test task

## Failure Context
None

## Retrieved Memory
None

## Previous Handoff
None

## Retrieved Project Memory
None

## Output Instructions
Done
EOF

    run validate_prepared_prompt_structure "$TEST_DIR/.ralph/context/prepared-prompt.md"
    [ "$status" -ne 0 ]
}

# ===== run_agent_iteration dry-run tests =====

@test "run_agent_iteration dry-run returns valid response envelope" {
    local response
    response="$(run_agent_iteration "test prompt" "$TEST_DIR/.ralph/config/context-prep-schema.json" "$TEST_DIR/.ralph/config/mcp-context.json" 5)"
    [[ "$(echo "$response" | jq -r '.type')" == "result" ]]
}

@test "run_agent_iteration dry-run response is parseable" {
    local response
    response="$(run_agent_iteration "test prompt" "$TEST_DIR/.ralph/config/context-prep-schema.json" "$TEST_DIR/.ralph/config/mcp-context.json" 5)"
    # The dry-run result is "{}" which is valid JSON
    local result
    result="$(echo "$response" | jq -r '.result')"
    echo "$result" | jq . >/dev/null
}

# ===== build_pass_input tests =====

@test "build_pass_input includes pass name and iteration details" {
    create_sample_handoff "$TEST_DIR/.ralph/handoffs/handoff-001.json"
    local output
    output="$(build_pass_input "review" "$TEST_DIR/.ralph/handoffs/handoff-001.json" 1 "TASK-002")"
    [[ "$output" == *"review"* ]]
    [[ "$output" == *"Iteration: 1"* ]]
    [[ "$output" == *"TASK-002"* ]]
}

# ===== Integration: context agent mode with handoff schema signals =====

@test "handoff schema supports request_research field" {
    local handoff_with_research='{
        "task_completed": {"task_id": "T1", "summary": "done", "fully_complete": true},
        "deviations": [], "bugs_encountered": [], "architectural_notes": [],
        "unfinished_business": [], "recommendations": [],
        "files_touched": [], "plan_amendments": [], "tests_added": [],
        "constraints_discovered": [],
        "request_research": ["API rate limits", "OAuth flow"],
        "summary": "done",
        "freeform": "I need more information about API rate limits and OAuth flow before proceeding."
    }'
    local topics
    topics="$(echo "$handoff_with_research" | jq -r '.request_research | join(", ")')"
    [[ "$topics" == "API rate limits, OAuth flow" ]]
}

@test "handoff schema supports request_human_review field" {
    local handoff_with_review='{
        "task_completed": {"task_id": "T1", "summary": "done", "fully_complete": true},
        "deviations": [], "bugs_encountered": [], "architectural_notes": [],
        "unfinished_business": [], "recommendations": [],
        "files_touched": [], "plan_amendments": [], "tests_added": [],
        "constraints_discovered": [],
        "request_human_review": {"needed": true, "reason": "Security-sensitive change"},
        "summary": "done",
        "freeform": "This change modifies authentication flow and should be reviewed by a human."
    }'
    local needed
    needed="$(echo "$handoff_with_review" | jq -r '.request_human_review.needed')"
    [[ "$needed" == "true" ]]
}

@test "handoff schema supports confidence_level field" {
    local handoff_with_confidence='{
        "task_completed": {"task_id": "T1", "summary": "done", "fully_complete": true},
        "deviations": [], "bugs_encountered": [], "architectural_notes": [],
        "unfinished_business": [], "recommendations": [],
        "files_touched": [], "plan_amendments": [], "tests_added": [],
        "constraints_discovered": [],
        "confidence_level": "low",
        "summary": "done",
        "freeform": "I am not confident about the error handling approach."
    }'
    local level
    level="$(echo "$handoff_with_confidence" | jq -r '.confidence_level')"
    [[ "$level" == "low" ]]
}

# ===== MCP transport resolution in agents =====

@test "run_context_prep uses HTTP config when resolve_mcp_config available and transport is http" {
    # Source cli-ops.sh to make resolve_mcp_config available
    source "$PROJ_ROOT/.ralph/lib/cli-ops.sh"

    export RALPH_MCP_TRANSPORT=http
    echo '{"mcpServers":{}}' > "$TEST_DIR/.ralph/config/mcp-context-http.json"

    # Override run_agent_iteration to capture the mcp_config arg (arg $3)
    local captured_mcp_config_file="$TEST_DIR/captured_mcp_config.txt"
    run_agent_iteration() {
        echo "$3" > "$captured_mcp_config_file"
        # Return a valid dry-run-like response
        echo '{"type":"result","subtype":"success","cost_usd":0,"duration_ms":0,"duration_api_ms":0,"is_error":false,"num_turns":1,"result":"{\"action\":\"proceed\",\"reason\":\"test\",\"stuck_detection\":{\"is_stuck\":false}}"}'
    }

    # Create required handoff for prep input
    create_sample_handoff "$TEST_DIR/.ralph/handoffs/handoff-001.json" "TASK-002" true

    # Update state to iteration 1
    cat > "$TEST_DIR/.ralph/state.json" <<'EOF'
{"current_iteration":1,"last_compaction_iteration":0,"coding_iterations_since_compaction":1,"total_handoff_bytes_since_compaction":0,"last_task_id":"TASK-001","started_at":"2026-02-06T10:00:00Z","status":"running"}
EOF

    local task_json='{"id":"TASK-002","title":"Test","description":"Test","acceptance_criteria":["works"],"depends_on":["TASK-001"],"skills":[],"needs_docs":false,"libraries":[]}'
    run run_context_prep "$task_json" 2 "agent-orchestrated"
    [[ "$status" -eq 0 ]]

    # Verify the HTTP variant was actually selected
    local used_config
    used_config="$(cat "$captured_mcp_config_file")"
    [[ "$used_config" == *"mcp-context-http.json" ]]
}
