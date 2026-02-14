#!/usr/bin/env bats

# claudemd.bats — Tests for CLAUDE.md bootstrap and update pass integration
#
# Coverage:
#   - build_bootstrap_claude_md_input() manifest generation
#   - bootstrap_claude_md() guard conditions (exists, dry-run, missing files)
#   - build_pass_input() claudemd-update pass-specific context
#   - agents.json claudemd-update pass configuration

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
    echo "# Bootstrap Prompt" > "$TEST_DIR/.ralph/templates/claude-md-bootstrap-prompt.md"
    echo "# Update Prompt" > "$TEST_DIR/.ralph/templates/claude-md-update-prompt.md"
    echo "# Context Prep System Prompt" > "$TEST_DIR/.ralph/templates/context-prep-prompt.md"
    echo "# Context Post System Prompt" > "$TEST_DIR/.ralph/templates/context-post-prompt.md"
    echo "## When You're Done" > "$TEST_DIR/.ralph/templates/coding-prompt-footer.md"

    # Create config files
    cp "$PROJ_ROOT/.ralph/config/claude-md-bootstrap-schema.json" "$TEST_DIR/.ralph/config/"
    cp "$PROJ_ROOT/.ralph/config/claude-md-update-schema.json" "$TEST_DIR/.ralph/config/"

    cat > "$TEST_DIR/.ralph/config/context-prep-schema.json" <<'EOF'
{
  "type": "object",
  "properties": {
    "action": { "type": "string" },
    "reason": { "type": "string" },
    "stuck_detection": { "type": "object", "properties": { "is_stuck": { "type": "boolean" } }, "required": ["is_stuck"] }
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

# ===== build_bootstrap_claude_md_input tests =====

@test "build_bootstrap_claude_md_input includes plan file pointer" {
    local output
    output="$(build_bootstrap_claude_md_input)"
    [[ "$output" == *"plan.json"* ]]
}

@test "build_bootstrap_claude_md_input includes first-iteration template pointer" {
    echo "# First iteration guidance" > "$TEST_DIR/.ralph/templates/first-iteration.md"
    local output
    output="$(build_bootstrap_claude_md_input)"
    [[ "$output" == *"first-iteration.md"* ]]
}

@test "build_bootstrap_claude_md_input includes detected project files" {
    echo '{"name": "test-project"}' > "$TEST_DIR/package.json"
    local output
    output="$(build_bootstrap_claude_md_input)"
    [[ "$output" == *"package.json"* ]]
}

@test "build_bootstrap_claude_md_input detects multiple project manifests" {
    echo '{}' > "$TEST_DIR/package.json"
    echo '{}' > "$TEST_DIR/tsconfig.json"
    local output
    output="$(build_bootstrap_claude_md_input)"
    [[ "$output" == *"package.json"* ]]
    [[ "$output" == *"tsconfig.json"* ]]
}

@test "build_bootstrap_claude_md_input shows no manifests when none exist" {
    local output
    output="$(build_bootstrap_claude_md_input)"
    [[ "$output" == *"No standard project manifests found"* ]]
}

@test "build_bootstrap_claude_md_input includes validation commands" {
    export RALPH_VALIDATION_COMMANDS=("npx jest" "npx eslint src/")
    local output
    output="$(build_bootstrap_claude_md_input)"
    [[ "$output" == *"npx jest"* ]]
    [[ "$output" == *"npx eslint src/"* ]]
}

@test "build_bootstrap_claude_md_input includes project root path" {
    local output
    output="$(build_bootstrap_claude_md_input)"
    [[ "$output" == *"$TEST_DIR"* ]]
}

@test "build_bootstrap_claude_md_input includes output target" {
    local output
    output="$(build_bootstrap_claude_md_input)"
    [[ "$output" == *"CLAUDE.md"* ]]
}

# ===== bootstrap_claude_md guard tests =====

@test "bootstrap_claude_md skips when CLAUDE.md already exists" {
    echo "# Existing conventions" > "$TEST_DIR/CLAUDE.md"
    run bootstrap_claude_md
    [[ "$status" -eq 0 ]]
    # Should still contain original content (unchanged)
    [[ "$(cat "$TEST_DIR/CLAUDE.md")" == "# Existing conventions" ]]
}

@test "bootstrap_claude_md skips in dry-run mode" {
    export DRY_RUN="true"
    run bootstrap_claude_md
    [[ "$status" -eq 0 ]]
    # CLAUDE.md should NOT be created (dry-run skips agent invocation)
    [[ ! -f "$TEST_DIR/CLAUDE.md" ]]
}

@test "bootstrap_claude_md skips when schema file is missing" {
    rm -f "$TEST_DIR/.ralph/config/claude-md-bootstrap-schema.json"
    export DRY_RUN="false"
    run bootstrap_claude_md
    [[ "$status" -eq 0 ]]
    [[ ! -f "$TEST_DIR/CLAUDE.md" ]]
}

@test "bootstrap_claude_md skips when template file is missing" {
    rm -f "$TEST_DIR/.ralph/templates/claude-md-bootstrap-prompt.md"
    export DRY_RUN="false"
    run bootstrap_claude_md
    [[ "$status" -eq 0 ]]
    [[ ! -f "$TEST_DIR/CLAUDE.md" ]]
}

@test "bootstrap_claude_md returns 0 even on failure (non-fatal)" {
    # Remove both schema and template to ensure failure path
    rm -f "$TEST_DIR/.ralph/config/claude-md-bootstrap-schema.json"
    rm -f "$TEST_DIR/.ralph/templates/claude-md-bootstrap-prompt.md"
    export DRY_RUN="false"
    run bootstrap_claude_md
    [[ "$status" -eq 0 ]]
}

# ===== build_pass_input tests for claudemd-update =====

@test "build_pass_input adds CLAUDE.md pointer for claudemd-update pass" {
    echo "# Project conventions" > "$TEST_DIR/CLAUDE.md"
    local output
    output="$(build_pass_input "claudemd-update" "$TEST_DIR/.ralph/handoffs/handoff-001.json" 3 "TASK-002")"
    [[ "$output" == *"CLAUDE.md"* ]]
}

@test "build_pass_input adds knowledge index pointer for claudemd-update pass" {
    echo "# Knowledge Index" > "$TEST_DIR/.ralph/knowledge-index.md"
    local output
    output="$(build_pass_input "claudemd-update" "$TEST_DIR/.ralph/handoffs/handoff-001.json" 3 "TASK-002")"
    [[ "$output" == *"knowledge-index.md"* ]]
}

@test "build_pass_input does not add CLAUDE.md pointer for other passes" {
    echo "# Project conventions" > "$TEST_DIR/CLAUDE.md"
    local output
    output="$(build_pass_input "review" "$TEST_DIR/.ralph/handoffs/handoff-001.json" 3 "TASK-002")"
    # Generic fields present
    [[ "$output" == *"Iteration: 3"* ]]
    [[ "$output" == *"TASK-002"* ]]
    # CLAUDE.md-specific pointer NOT present
    [[ "$output" != *"CLAUDE.md:"* ]]
}

@test "build_pass_input includes standard fields for claudemd-update pass" {
    local output
    output="$(build_pass_input "claudemd-update" "$TEST_DIR/.ralph/handoffs/handoff-001.json" 5 "TASK-003")"
    [[ "$output" == *"Iteration: 5"* ]]
    [[ "$output" == *"TASK-003"* ]]
    [[ "$output" == *"plan.json"* ]]
}

# ===== agents.json configuration tests =====

@test "claudemd-update pass appears in canonical agents.json" {
    local pass
    pass="$(jq '.passes[] | select(.name == "claudemd-update")' "$PROJ_ROOT/.ralph/config/agents.json")"
    [[ -n "$pass" ]]
}

@test "claudemd-update pass has correct trigger" {
    local trigger
    trigger="$(jq -r '.passes[] | select(.name == "claudemd-update") | .trigger' "$PROJ_ROOT/.ralph/config/agents.json")"
    [[ "$trigger" == "periodic:3" ]]
}

@test "claudemd-update pass is enabled by default" {
    local enabled
    enabled="$(jq -r '.passes[] | select(.name == "claudemd-update") | .enabled' "$PROJ_ROOT/.ralph/config/agents.json")"
    [[ "$enabled" == "true" ]]
}

@test "claudemd-update pass is not read-only" {
    local read_only
    read_only="$(jq -r '.passes[] | select(.name == "claudemd-update") | .read_only' "$PROJ_ROOT/.ralph/config/agents.json")"
    [[ "$read_only" == "false" ]]
}

@test "claudemd-update pass references existing template" {
    local template
    template="$(jq -r '.passes[] | select(.name == "claudemd-update") | .prompt_template' "$PROJ_ROOT/.ralph/config/agents.json")"
    [[ -f "$PROJ_ROOT/.ralph/templates/$template" ]]
}

@test "claudemd-update pass references existing schema" {
    local schema
    schema="$(jq -r '.passes[] | select(.name == "claudemd-update") | .schema' "$PROJ_ROOT/.ralph/config/agents.json")"
    [[ -f "$PROJ_ROOT/.ralph/config/$schema" ]]
}

# ===== Schema validation tests =====

@test "claude-md-bootstrap-schema.json is valid JSON" {
    jq . "$PROJ_ROOT/.ralph/config/claude-md-bootstrap-schema.json" >/dev/null
}

@test "claude-md-update-schema.json is valid JSON" {
    jq . "$PROJ_ROOT/.ralph/config/claude-md-update-schema.json" >/dev/null
}

@test "claude-md-bootstrap-schema requires generated and summary fields" {
    local required
    required="$(jq -r '.required | sort | join(",")' "$PROJ_ROOT/.ralph/config/claude-md-bootstrap-schema.json")"
    [[ "$required" == "generated,summary" ]]
}

@test "claude-md-update-schema requires updated and summary fields" {
    local required
    required="$(jq -r '.required | sort | join(",")' "$PROJ_ROOT/.ralph/config/claude-md-update-schema.json")"
    [[ "$required" == "summary,updated" ]]
}
