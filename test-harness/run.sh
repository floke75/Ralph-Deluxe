#!/usr/bin/env bash
set -euo pipefail

# PURPOSE: Execute Ralph against a prepared test workspace.
# USAGE: ./test-harness/run.sh <workspace_path>
# OUTPUT: Ralph orchestrator output to stderr, final summary to stdout.
#
# The script runs ralph.sh in agent-orchestrated mode and captures the exit code.
# After completion, it prints a summary of task results.

WORKSPACE="${1:?Usage: run.sh <workspace_path>}"

log() { echo "[run] $*" >&2; }

# Verify workspace
if [[ ! -f "$WORKSPACE/.ralph/ralph.sh" ]]; then
    log "ERROR: $WORKSPACE/.ralph/ralph.sh not found. Run setup.sh first."
    exit 1
fi

if [[ ! -f "$WORKSPACE/plan.json" ]]; then
    log "ERROR: $WORKSPACE/plan.json not found."
    exit 1
fi

log "Starting Ralph in $WORKSPACE"
log "Plan: $(jq -r '.project' "$WORKSPACE/plan.json") — $(jq '.tasks | length' "$WORKSPACE/plan.json") tasks"

# Run Ralph
RALPH_EXIT=0
(cd "$WORKSPACE" && bash .ralph/ralph.sh --mode agent-orchestrated --max-iterations 30) || RALPH_EXIT=$?

log "Ralph exited with code $RALPH_EXIT"

# Print summary
echo "=== Ralph Test Run Summary ==="
echo "Workspace: $WORKSPACE"
echo "Exit code: $RALPH_EXIT"

if [[ -f "$WORKSPACE/.ralph/state.json" ]]; then
    echo "Status: $(jq -r '.status // "unknown"' "$WORKSPACE/.ralph/state.json")"
    echo "Iterations: $(jq -r '.current_iteration // 0' "$WORKSPACE/.ralph/state.json")"
fi

if [[ -f "$WORKSPACE/plan.json" ]]; then
    echo "Tasks completed: $(jq '[.tasks[] | select(.status == "done")] | length' "$WORKSPACE/plan.json")"
    echo "Tasks failed: $(jq '[.tasks[] | select(.status == "failed")] | length' "$WORKSPACE/plan.json")"
    echo "Tasks skipped: $(jq '[.tasks[] | select(.status == "skipped")] | length' "$WORKSPACE/plan.json")"
    echo "Tasks pending: $(jq '[.tasks[] | select(.status == "pending")] | length' "$WORKSPACE/plan.json")"
fi

exit $RALPH_EXIT
