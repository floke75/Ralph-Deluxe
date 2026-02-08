#!/usr/bin/env bash
# git-ops.sh — Atomic checkpoint/rollback for iteration safety
#
# MODULE: Checkpoint lifecycle across the iteration flow
#   1) ensure_clean_state() runs once at startup so iteration 1 begins from a
#      commit-backed baseline.
#   2) create_checkpoint() captures HEAD before each coding cycle starts.
#   3) On validation failure (or cycle error), rollback_to_checkpoint() restores
#      that SHA and removes transient untracked files.
#   4) On validation success, commit_iteration() records the iteration outcome
#      and establishes the next cycle's baseline.
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
# ASSUMPTION: Iteration commits are local, linear commits on the current branch;
# this module does not rebase, merge, or resolve conflicts.
# ASSUMPTION: Conflict handling is delegated to higher-level orchestration/user
# workflow; git command failures bubble up to the caller.

# Checkpoint creation: capture current HEAD SHA as the rollback target before a
# coding cycle mutates the working tree.
# Stdout: 40-char git SHA.
create_checkpoint() {
    local checkpoint
    checkpoint="$(git rev-parse HEAD)"
    log "debug" "Created checkpoint: $checkpoint"
    echo "$checkpoint"
}

# Rollback behavior on validation failure: hard-reset to checkpoint SHA and
# clean untracked files to guarantee a known-good post-failure state.
# Preserves .ralph/ state files (handoffs, logs, control) so orchestrator can
# continue operating after a failed validation cycle.
# SIDE EFFECT: Destroys all uncommitted changes. Cleans untracked files.
# CALLER: ralph.sh main loop on coding_cycle failure or validation failure.
rollback_to_checkpoint() {
    local checkpoint="$1"
    log "info" "Rolling back to checkpoint: $checkpoint"
    git reset --hard "$checkpoint"
    git clean -fd --exclude=.ralph/
    log "info" "Rollback complete"
}

# Commit behavior on successful iteration: stage all changes and create a
# structured commit only after validation passes.
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
# ASSUMPTION: Auto-commit succeeds without conflicts because it does not perform
# history integration operations (merge/rebase); failures are surfaced upstream.
# CALLER: ralph.sh main(), after config load, before main loop.
ensure_clean_state() {
    if [[ -n "$(git status --porcelain)" ]]; then
        log "warn" "Working directory not clean, committing current state"
        git add -A
        git commit -m "ralph: auto-commit before orchestration start"
    fi
}
