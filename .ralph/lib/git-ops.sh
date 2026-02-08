#!/usr/bin/env bash
# git-ops.sh — Atomic checkpoint/rollback for iteration safety
#
# PURPOSE: Provides transactional semantics for coding iterations. Each iteration
# gets a checkpoint before it runs; if validation fails, we rollback to it. This
# guarantees the repo is never left in a half-modified state between iterations.
#
# DEPENDENCIES:
#   Called by: ralph.sh main loop (steps 3, 5-6)
#   Depends on: git CLI, log() from ralph.sh
#   Globals read: RALPH_COMMIT_PREFIX (optional, default "ralph")
#
# DATA FLOW:
#   create_checkpoint() → SHA stored in local var in ralph.sh main loop
#   rollback_to_checkpoint() ← called on validation failure or coding cycle error
#   commit_iteration() ← called on validation success
#   ensure_clean_state() ← called once at orchestrator startup, before main loop
#
# INVARIANT: After every iteration, repo is either committed (success) or
# rolled back to checkpoint (failure). No partial states persist.
# INVARIANT: .ralph/ directory is NEVER cleaned by rollback (--exclude=.ralph/).

# Capture HEAD SHA as a rollback target. Called before each coding cycle.
# Stdout: 40-char git SHA
create_checkpoint() {
    local checkpoint
    checkpoint="$(git rev-parse HEAD)"
    log "debug" "Created checkpoint: $checkpoint"
    echo "$checkpoint"
}

# Hard-reset to checkpoint SHA on failure. Preserves .ralph/ state files
# (handoffs, logs, control) so orchestrator can continue operating.
# SIDE EFFECT: Destroys all uncommitted changes. Cleans untracked files.
# CALLER: ralph.sh main loop on coding_cycle failure or validation failure.
rollback_to_checkpoint() {
    local checkpoint="$1"
    log "info" "Rolling back to checkpoint: $checkpoint"
    git reset --hard "$checkpoint"
    git clean -fd --exclude=.ralph/
    log "info" "Rollback complete"
}

# Commit all working tree changes with structured message format.
# Format: ralph[N]: TASK-ID — description (parsed by progress tooling).
# CALLER: ralph.sh main loop step 6a, only after validation passes.
commit_iteration() {
    local iteration="$1"
    local task_id="$2"
    local message="${3:-passed validation}"
    git add -A
    git commit -m "${RALPH_COMMIT_PREFIX:-ralph}[${iteration}]: ${task_id} — ${message}"
    log "info" "Committed iteration $iteration for $task_id"
}

# Auto-commit dirty working tree at orchestrator startup so checkpoint/rollback
# has a clean base. Without this, a dirty start state would be lost on first rollback.
# CALLER: ralph.sh main(), after config load, before main loop.
ensure_clean_state() {
    if [[ -n "$(git status --porcelain)" ]]; then
        log "warn" "Working directory not clean, committing current state"
        git add -A
        git commit -m "ralph: auto-commit before orchestration start"
    fi
}
