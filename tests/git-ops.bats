#!/usr/bin/env bats
# Tests for .ralph/lib/git-ops.sh

# Provide a stub log() function since git-ops.sh uses it
log() {
    : # no-op for tests
}

RALPH_COMMIT_PREFIX="ralph"

setup() {
    # Create a temporary directory for the test git repo
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR" || exit 1

    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
    git config commit.gpgsign false
    git config tag.gpgsign false

    # Create an initial commit so HEAD exists
    echo "initial" > file.txt
    git add -A
    git commit --quiet -m "initial commit"

    # Source the module under test
    source "${BATS_TEST_DIRNAME}/../.ralph/lib/git-ops.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

@test "create_checkpoint captures current HEAD" {
    local expected
    expected="$(git rev-parse HEAD)"

    run create_checkpoint
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
}

@test "rollback_to_checkpoint restores previous state" {
    # Capture checkpoint at initial state
    local checkpoint
    checkpoint="$(create_checkpoint)"

    # Make changes
    echo "modified" > file.txt
    git add -A
    git commit --quiet -m "modify file"

    # Verify the file was changed
    [ "$(cat file.txt)" = "modified" ]

    # Rollback
    rollback_to_checkpoint "$checkpoint"

    # Verify file is restored
    [ "$(cat file.txt)" = "initial" ]
}

@test "rollback_to_checkpoint removes untracked files" {
    local checkpoint
    checkpoint="$(create_checkpoint)"

    # Create untracked files (simulating a failed iteration)
    echo "new file" > new-file.txt
    mkdir -p subdir
    echo "nested" > subdir/nested.txt

    # Rollback should clean untracked files
    rollback_to_checkpoint "$checkpoint"

    # Verify untracked files are gone
    [ ! -f "new-file.txt" ]
    [ ! -d "subdir" ]
}

@test "rollback_to_checkpoint preserves .ralph/ directory" {
    local checkpoint
    checkpoint="$(create_checkpoint)"

    # Create a .ralph directory with content
    mkdir -p .ralph
    echo "state data" > .ralph/state.json

    # Create an untracked file outside .ralph
    echo "should be removed" > outside-ralph.txt

    rollback_to_checkpoint "$checkpoint"

    # .ralph/ should be preserved
    [ -f ".ralph/state.json" ]
    # Outside file should be removed
    [ ! -f "outside-ralph.txt" ]
}

@test "commit_iteration creates a properly formatted commit" {
    # Make a change to commit
    echo "new content" > new-file.txt

    commit_iteration "5" "TASK-003" "passed validation"

    local commit_msg
    commit_msg="$(git log -1 --format=%s)"
    [ "$commit_msg" = "ralph[5]: TASK-003 — passed validation" ]
}

@test "commit_iteration uses default message when none provided" {
    echo "another change" > another-file.txt

    commit_iteration "2" "TASK-001"

    local commit_msg
    commit_msg="$(git log -1 --format=%s)"
    [ "$commit_msg" = "ralph[2]: TASK-001 — passed validation" ]
}

@test "commit_iteration uses custom commit prefix" {
    RALPH_COMMIT_PREFIX="custom"
    echo "prefix test" > prefix-file.txt

    commit_iteration "1" "TASK-010" "custom message"

    local commit_msg
    commit_msg="$(git log -1 --format=%s)"
    [ "$commit_msg" = "custom[1]: TASK-010 — custom message" ]

    RALPH_COMMIT_PREFIX="ralph"
}

@test "ensure_clean_state commits dirty working directory" {
    # Dirty the working directory
    echo "dirty" > dirty-file.txt

    ensure_clean_state

    # Verify the commit was created
    local commit_msg
    commit_msg="$(git log -1 --format=%s)"
    [ "$commit_msg" = "ralph: auto-commit before orchestration start" ]

    # Verify working directory is clean
    local status_output
    status_output="$(git status --porcelain)"
    [ -z "$status_output" ]
}

@test "ensure_clean_state does nothing on clean working directory" {
    local head_before
    head_before="$(git rev-parse HEAD)"

    ensure_clean_state

    local head_after
    head_after="$(git rev-parse HEAD)"

    # HEAD should not change — no new commit
    [ "$head_before" = "$head_after" ]
}
