#!/usr/bin/env bash
set -euo pipefail

# PURPOSE: Outer loop for autonomous pipeline testing.
# USAGE: ./test-harness/loop.sh [workspace_path]
#
# Runs the full cycle: setup → run → analyze → report.
# Designed to be invoked by Claude Code for autonomous tuning iterations.
# Each invocation creates a fresh workspace and generates a timestamped report.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[loop] $*" >&2; }

WORKSPACE="${1:-}"

# --- Step 1: Setup ---
log "=== Phase 1: Setup ==="
if [[ -z "$WORKSPACE" ]]; then
    WORKSPACE=$(bash "$SCRIPT_DIR/setup.sh")
else
    WORKSPACE=$(bash "$SCRIPT_DIR/setup.sh" "$WORKSPACE")
fi
log "Workspace: $WORKSPACE"

# --- Step 2: Run Ralph ---
log "=== Phase 2: Run Ralph ==="
RALPH_EXIT=0
bash "$SCRIPT_DIR/run.sh" "$WORKSPACE" || RALPH_EXIT=$?
log "Ralph exit code: $RALPH_EXIT"

# --- Step 3: Analyze ---
log "=== Phase 3: Analyze ==="
REPORT_DIR=$(bash "$SCRIPT_DIR/analyze.sh" "$WORKSPACE")
log "Report: $REPORT_DIR"

# --- Step 4: Summary ---
log "=== Complete ==="
log "Workspace: $WORKSPACE"
log "Report: $REPORT_DIR"
log "  report.json — machine-parseable"
log "  report.md   — human-readable"

# Print paths for the caller
echo "WORKSPACE=$WORKSPACE"
echo "REPORT_DIR=$REPORT_DIR"
echo "REPORT_JSON=$REPORT_DIR/report.json"
echo "REPORT_MD=$REPORT_DIR/report.md"
