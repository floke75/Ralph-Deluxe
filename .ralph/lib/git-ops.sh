#!/usr/bin/env bash
# git-ops.sh — Git checkpoint, rollback, and commit functions for Ralph Deluxe

# Capture current HEAD as a checkpoint
create_checkpoint() {
    local checkpoint
    checkpoint="$(git rev-parse HEAD)"
    log "debug" "Created checkpoint: $checkpoint"
    echo "$checkpoint"
}

# Reset to checkpoint, clean untracked files (preserving .ralph/)
rollback_to_checkpoint() {
    local checkpoint="$1"
    log "info" "Rolling back to checkpoint: $checkpoint"
    git reset --hard "$checkpoint"
    git clean -fd --exclude=.ralph/
    log "info" "Rollback complete"
}

# Commit all changes with ralph-format message
commit_iteration() {
    local iteration="$1"
    local task_id="$2"
    local message="${3:-passed validation}"
    git add -A
    git commit -m "${RALPH_COMMIT_PREFIX:-ralph}[${iteration}]: ${task_id} — ${message}"
    log "info" "Committed iteration $iteration for $task_id"
}

# Check for uncommitted changes at startup and auto-commit if dirty
ensure_clean_state() {
    if [[ -n "$(git status --porcelain)" ]]; then
        log "warn" "Working directory not clean, committing current state"
        git add -A
        git commit -m "ralph: auto-commit before orchestration start"
    fi
}
