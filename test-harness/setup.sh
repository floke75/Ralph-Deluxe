#!/usr/bin/env bash
set -euo pipefail

# PURPOSE: Create an isolated test workspace with the project template and Ralph installed.
# USAGE: ./test-harness/setup.sh [workspace_path]
# OUTPUT: Prints the workspace path to stdout (last line).
#
# Steps:
#   1. Create workspace directory
#   2. Copy project template files
#   3. npm install
#   4. Initialize git repo with initial commit
#   5. Copy .ralph/ from Ralph Deluxe (orchestrator + modules)
#   6. Overlay test-specific configs (ralph.conf, plan.json, first-iteration.md, skills)
#   7. Commit config layer

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_DELUXE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
WORKSPACE="${1:-/tmp/ralph-test-${TIMESTAMP}}"

log() { echo "[setup] $*" >&2; }

# --- 1. Create workspace ---
log "Creating workspace at $WORKSPACE"
mkdir -p "$WORKSPACE"

# --- 2. Copy project template ---
log "Copying project template"
cp -R "$SCRIPT_DIR/project-template/." "$WORKSPACE/"

# --- 3. npm install + Playwright browser ---
log "Running npm install (this may take a minute)"
(cd "$WORKSPACE" && npm install --loglevel=error 2>&1) >&2
log "Installing Playwright Chromium browser"
(cd "$WORKSPACE" && npx playwright install chromium 2>&1) >&2

# --- 4. Initialize git repo ---
log "Initializing git repo"
(
  cd "$WORKSPACE"
  git init -q
  git config user.email "ralph-test@test.local"
  git config user.name "Ralph Test Harness"
  git add -A
  git commit -q -m "Initial project template"
)

# --- 5. Copy .ralph/ from Ralph Deluxe ---
log "Installing Ralph orchestrator"
mkdir -p "$WORKSPACE/.ralph"

# Copy core orchestrator
cp "$RALPH_DELUXE_ROOT/.ralph/ralph.sh" "$WORKSPACE/.ralph/ralph.sh"

# Copy library modules
cp -R "$RALPH_DELUXE_ROOT/.ralph/lib" "$WORKSPACE/.ralph/lib"

# Copy config directory (schemas, MCP configs, agents.json)
cp -R "$RALPH_DELUXE_ROOT/.ralph/config" "$WORKSPACE/.ralph/config"

# Copy templates
cp -R "$RALPH_DELUXE_ROOT/.ralph/templates" "$WORKSPACE/.ralph/templates"

# Create runtime directories
mkdir -p "$WORKSPACE/.ralph/handoffs"
mkdir -p "$WORKSPACE/.ralph/logs/validation"
mkdir -p "$WORKSPACE/.ralph/context"
mkdir -p "$WORKSPACE/.ralph/control"
mkdir -p "$WORKSPACE/.ralph/skills"

# Initialize control file
echo '{"pending":[]}' > "$WORKSPACE/.ralph/control/commands.json"

# --- 6. Overlay test-specific configs ---
log "Applying test configuration overlay"

# Ralph config (overrides the default)
cp "$SCRIPT_DIR/config/ralph.conf" "$WORKSPACE/.ralph/config/ralph.conf"

# Plan file
cp "$SCRIPT_DIR/config/plan.json" "$WORKSPACE/plan.json"

# First-iteration template (overrides the self-improvement one)
cp "$SCRIPT_DIR/config/first-iteration.md" "$WORKSPACE/.ralph/templates/first-iteration.md"

# Skills
cp "$SCRIPT_DIR/skills/"*.md "$WORKSPACE/.ralph/skills/"

# --- 7. Commit config layer ---
log "Committing configuration"
(
  cd "$WORKSPACE"
  git add -A
  git commit -q -m "Configure Ralph for test run"
)

# --- Done ---
log "Workspace ready at $WORKSPACE"
log "Tasks: $(jq '.tasks | length' "$WORKSPACE/plan.json")"
log "Mode: $(grep '^RALPH_MODE=' "$WORKSPACE/.ralph/config/ralph.conf" | cut -d= -f2 | tr -d '"')"

echo "$WORKSPACE"
