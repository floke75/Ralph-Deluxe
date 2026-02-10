#!/usr/bin/env bats

# Scope: tests for template verification/restore in ralph.sh.
# verify_templates() detects agent-overwritten templates and restores from git.

PROJ_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Stub log function (must be defined before sourcing ralph.sh)
log() { :; }
export -f log

setup() {
    TEST_DIR="$(mktemp -d)"
    export TEST_DIR

    # Create minimal .ralph structure with templates
    mkdir -p "$TEST_DIR/.ralph/templates"
    mkdir -p "$TEST_DIR/.ralph/config"
    mkdir -p "$TEST_DIR/.ralph/lib"
    mkdir -p "$TEST_DIR/.ralph/logs"

    # Create test templates
    echo "# Coding prompt template" > "$TEST_DIR/.ralph/templates/coding-prompt.md"
    echo "# First iteration" > "$TEST_DIR/.ralph/templates/first-iteration.md"
    echo "# Memory prompt" > "$TEST_DIR/.ralph/templates/memory-prompt.md"

    # Create minimal state.json
    cat > "$TEST_DIR/.ralph/state.json" <<'EOF'
{
  "current_iteration": 0,
  "status": "idle",
  "mode": "handoff-only"
}
EOF

    # Source ralph.sh to get verify_templates.
    # IMPORTANT: ralph.sh overwrites RALPH_DIR/PROJECT_ROOT at source time,
    # so we must re-set them AFTER sourcing.
    source "$PROJ_ROOT/.ralph/ralph.sh"
    export RALPH_DIR="$TEST_DIR/.ralph"
    export PROJECT_ROOT="$TEST_DIR"
    export LOG_LEVEL="error"
    export LOG_FILE=".ralph/logs/ralph.log"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# Helper: initialize a git repo in TEST_DIR with committed templates
_init_git_repo() {
    cd "$TEST_DIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    git add -A
    git commit -q -m "initial"
}

# ---------- verify_templates ----------

@test "verify_templates returns 0 when not in a git repo" {
    run verify_templates
    [[ "$status" -eq 0 ]]
}

@test "verify_templates returns 0 when templates are unmodified" {
    _init_git_repo
    run verify_templates
    [[ "$status" -eq 0 ]]
}

@test "verify_templates returns 1 when a template is modified" {
    _init_git_repo
    echo "MODIFIED" > "$TEST_DIR/.ralph/templates/coding-prompt.md"
    run verify_templates
    [[ "$status" -eq 1 ]]
}

@test "verify_templates --restore restores modified templates from git" {
    _init_git_repo
    local original
    original="$(cat "$TEST_DIR/.ralph/templates/coding-prompt.md")"

    # Modify a template
    echo "OVERWRITTEN BY AGENT" > "$TEST_DIR/.ralph/templates/coding-prompt.md"

    run verify_templates "--restore"
    # Returns 1 because it detected modifications
    [[ "$status" -eq 1 ]]

    # But the file should now be restored
    local restored
    restored="$(cat "$TEST_DIR/.ralph/templates/coding-prompt.md")"
    [[ "$restored" == "$original" ]]
}

@test "verify_templates detects multiple modified templates" {
    _init_git_repo
    echo "MODIFIED" > "$TEST_DIR/.ralph/templates/coding-prompt.md"
    echo "ALSO MODIFIED" > "$TEST_DIR/.ralph/templates/first-iteration.md"

    run verify_templates "--restore"
    [[ "$status" -eq 1 ]]

    # Both should be restored
    [[ "$(cat "$TEST_DIR/.ralph/templates/coding-prompt.md")" == "# Coding prompt template" ]]
    [[ "$(cat "$TEST_DIR/.ralph/templates/first-iteration.md")" == "# First iteration" ]]
}
