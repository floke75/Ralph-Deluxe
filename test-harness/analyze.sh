#!/usr/bin/env bash
set -euo pipefail

# PURPOSE: Analyze Ralph test run artifacts and generate structured report.
# USAGE: ./test-harness/analyze.sh <workspace_path> [output_dir]
# OUTPUT: Creates report.json and report.md in the output directory.
#
# Metrics collected:
#   - Task completion (done/failed/skipped/pending counts)
#   - Iteration count and retries per task
#   - Validation pass/fail rates and failure reasons
#   - Handoff quality (synthetic count, freeform length, field coverage)
#   - Context agent directives (proceed/skip/review/research)
#   - Knowledge index entries
#   - Timing and cost

WORKSPACE="${1:?Usage: analyze.sh <workspace_path> [output_dir]}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_DIR="${2:-$SCRIPT_DIR/results/run-$TIMESTAMP}"

log() { echo "[analyze] $*" >&2; }

mkdir -p "$OUTPUT_DIR"

# --- Copy artifacts ---
log "Copying artifacts from $WORKSPACE"
[[ -d "$WORKSPACE/.ralph/handoffs" ]] && cp -R "$WORKSPACE/.ralph/handoffs" "$OUTPUT_DIR/handoffs" || mkdir -p "$OUTPUT_DIR/handoffs"
[[ -f "$WORKSPACE/.ralph/logs/events.jsonl" ]] && cp "$WORKSPACE/.ralph/logs/events.jsonl" "$OUTPUT_DIR/events.jsonl" || touch "$OUTPUT_DIR/events.jsonl"
[[ -d "$WORKSPACE/.ralph/logs/validation" ]] && cp -R "$WORKSPACE/.ralph/logs/validation" "$OUTPUT_DIR/validation" || mkdir -p "$OUTPUT_DIR/validation"
[[ -f "$WORKSPACE/.ralph/state.json" ]] && cp "$WORKSPACE/.ralph/state.json" "$OUTPUT_DIR/state.json" || echo '{}' > "$OUTPUT_DIR/state.json"
[[ -f "$WORKSPACE/.ralph/knowledge-index.md" ]] && cp "$WORKSPACE/.ralph/knowledge-index.md" "$OUTPUT_DIR/knowledge-index.md" || true
[[ -f "$WORKSPACE/.ralph/knowledge-index.json" ]] && cp "$WORKSPACE/.ralph/knowledge-index.json" "$OUTPUT_DIR/knowledge-index.json" || true
[[ -f "$WORKSPACE/plan.json" ]] && cp "$WORKSPACE/plan.json" "$OUTPUT_DIR/plan-final.json" || true
[[ -f "$WORKSPACE/.ralph/logs/ralph.log" ]] && cp "$WORKSPACE/.ralph/logs/ralph.log" "$OUTPUT_DIR/ralph.log" || true

# --- Compute metrics ---
log "Computing metrics"

PLAN="$OUTPUT_DIR/plan-final.json"
EVENTS="$OUTPUT_DIR/events.jsonl"
HANDOFF_DIR="$OUTPUT_DIR/handoffs"
VALIDATION_DIR="$OUTPUT_DIR/validation"
STATE="$OUTPUT_DIR/state.json"

# Task completion
tasks_total=$(jq '.tasks | length' "$PLAN" 2>/dev/null || echo 0)
tasks_done=$(jq '[.tasks[] | select(.status == "done")] | length' "$PLAN" 2>/dev/null || echo 0)
tasks_failed=$(jq '[.tasks[] | select(.status == "failed")] | length' "$PLAN" 2>/dev/null || echo 0)
tasks_skipped=$(jq '[.tasks[] | select(.status == "skipped")] | length' "$PLAN" 2>/dev/null || echo 0)
tasks_pending=$(jq '[.tasks[] | select(.status == "pending")] | length' "$PLAN" 2>/dev/null || echo 0)

# Retries per task
retries_json=$(jq '[.tasks[] | select(.retry_count > 0) | {id: .id, title: .title, retries: .retry_count}]' "$PLAN" 2>/dev/null || echo '[]')
total_retries=$(jq '[.tasks[].retry_count // 0] | add // 0' "$PLAN" 2>/dev/null || echo 0)

# Iterations
total_iterations=$(jq -r '.current_iteration // 0' "$STATE" 2>/dev/null || echo 0)
final_status=$(jq -r '.status // "unknown"' "$STATE" 2>/dev/null || echo "unknown")

# Validation metrics
validation_pass=0
validation_fail=0
validation_errors="[]"
if [[ -d "$VALIDATION_DIR" ]]; then
    for vfile in "$VALIDATION_DIR"/iter-*.json; do
        [[ -f "$vfile" ]] || continue
        passed=$(jq -r '.passed' "$vfile" 2>/dev/null || echo "false")
        if [[ "$passed" == "true" ]]; then
            validation_pass=$((validation_pass + 1))
        else
            validation_fail=$((validation_fail + 1))
        fi
    done

    # Collect failure reasons
    validation_errors=$(
        for vfile in "$VALIDATION_DIR"/iter-*.json; do
            [[ -f "$vfile" ]] || continue
            jq -r '.checks[]? | select(.passed == false) | {command, exit_code, output: (.output[:300])}' "$vfile" 2>/dev/null
        done | jq -s '.' 2>/dev/null || echo '[]'
    )
fi
validation_total=$((validation_pass + validation_fail))

# Handoff metrics
handoff_count=0
synthetic_count=0
freeform_lengths="[]"
field_coverage="[]"
if [[ -d "$HANDOFF_DIR" ]]; then
    for hfile in "$HANDOFF_DIR"/handoff-*.json; do
        [[ -f "$hfile" ]] || continue
        handoff_count=$((handoff_count + 1))

        # Check for synthetic handoff marker
        summary=$(jq -r '.summary // ""' "$hfile" 2>/dev/null || echo "")
        if [[ "$summary" == *"Synthetic handoff"* ]]; then
            synthetic_count=$((synthetic_count + 1))
        fi
    done

    # Freeform lengths
    freeform_lengths=$(
        for hfile in "$HANDOFF_DIR"/handoff-*.json; do
            [[ -f "$hfile" ]] || continue
            jq '{file: input_filename, length: (.freeform // "" | length)}' "$hfile" 2>/dev/null
        done | jq -s '.' 2>/dev/null || echo '[]'
    )
    avg_freeform=$(echo "$freeform_lengths" | jq '[.[].length] | if length > 0 then (add / length | floor) else 0 end' 2>/dev/null || echo 0)

    # Structured field coverage (how many optional fields are populated)
    field_coverage=$(
        for hfile in "$HANDOFF_DIR"/handoff-*.json; do
            [[ -f "$hfile" ]] || continue
            jq '{
                file: input_filename,
                has_deviations: ((.deviations // []) | length > 0),
                has_bugs: ((.bugs_encountered // []) | length > 0),
                has_arch_notes: ((.architectural_notes // []) | length > 0),
                has_constraints: ((.constraints_discovered // []) | length > 0),
                has_files_touched: ((.files_touched // []) | length > 0),
                has_tests_added: ((.tests_added // []) | length > 0),
                has_recommendations: ((.recommendations // []) | length > 0),
                confidence: (.confidence_level // "not_set")
            }' "$hfile" 2>/dev/null
        done | jq -s '.' 2>/dev/null || echo '[]'
    )
fi

# Event-based metrics
stuck_detections=0
directive_proceed=0
directive_skip=0
directive_review=0
directive_research=0
if [[ -s "$EVENTS" ]]; then
    stuck_detections=$(grep -c '"stuck_detected"' "$EVENTS" 2>/dev/null || true)
    stuck_detections=${stuck_detections:-0}

    # Count directive-related events
    directive_skip=$(grep -c '"skip_task"' "$EVENTS" 2>/dev/null || true)
    directive_skip=${directive_skip:-0}
    directive_review=$(grep -c '"human_review_requested"' "$EVENTS" 2>/dev/null || true)
    directive_review=${directive_review:-0}

    # Timing
    first_ts=$(head -1 "$EVENTS" | jq -r '.timestamp // empty' 2>/dev/null || echo "")
    last_ts=$(tail -1 "$EVENTS" | jq -r '.timestamp // empty' 2>/dev/null || echo "")
fi

# Knowledge index
knowledge_entries=0
if [[ -f "$OUTPUT_DIR/knowledge-index.json" ]]; then
    knowledge_entries=$(jq 'length' "$OUTPUT_DIR/knowledge-index.json" 2>/dev/null || echo 0)
fi

# --- Generate report.json ---
log "Generating report.json"
cat > "$OUTPUT_DIR/report.json" <<ENDJSON
{
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "workspace": "$WORKSPACE",
  "completion": {
    "tasks_total": $tasks_total,
    "tasks_done": $tasks_done,
    "tasks_failed": $tasks_failed,
    "tasks_skipped": $tasks_skipped,
    "tasks_pending": $tasks_pending,
    "completion_rate": $(echo "scale=1; $tasks_done * 100 / $tasks_total" | bc 2>/dev/null || echo 0)
  },
  "iterations": {
    "total": $total_iterations,
    "final_status": "$final_status",
    "total_retries": $total_retries,
    "retries_by_task": $retries_json
  },
  "validation": {
    "total_runs": $validation_total,
    "passes": $validation_pass,
    "failures": $validation_fail,
    "pass_rate": $(if [[ $validation_total -gt 0 ]]; then echo "scale=1; $validation_pass * 100 / $validation_total" | bc 2>/dev/null || echo 0; else echo 0; fi),
    "failure_details": $validation_errors
  },
  "handoffs": {
    "total": $handoff_count,
    "synthetic_count": $synthetic_count,
    "avg_freeform_length": $avg_freeform,
    "freeform_lengths": $freeform_lengths,
    "field_coverage": $field_coverage
  },
  "context_agent": {
    "stuck_detections": $stuck_detections,
    "directives": {
      "skip": $directive_skip,
      "human_review": $directive_review
    }
  },
  "knowledge": {
    "index_entries": $knowledge_entries
  },
  "timing": {
    "first_event": "${first_ts:-}",
    "last_event": "${last_ts:-}"
  }
}
ENDJSON

# --- Generate report.md ---
log "Generating report.md"
cat > "$OUTPUT_DIR/report.md" <<ENDMD
# Ralph Pipeline Test Report

Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Workspace: \`$WORKSPACE\`

## Task Completion

| Metric | Value |
|--------|-------|
| Total tasks | $tasks_total |
| Completed | $tasks_done |
| Failed | $tasks_failed |
| Skipped | $tasks_skipped |
| Pending | $tasks_pending |
| **Completion rate** | **$(echo "scale=1; $tasks_done * 100 / $tasks_total" | bc 2>/dev/null || echo 0)%** |

## Iteration Summary

| Metric | Value |
|--------|-------|
| Total iterations | $total_iterations |
| Final status | $final_status |
| Total retries | $total_retries |

### Retries by Task
$(echo "$retries_json" | jq -r '.[] | "- **\(.id)** (\(.title)): \(.retries) retries"' 2>/dev/null || echo "- None")

## Validation

| Metric | Value |
|--------|-------|
| Total validation runs | $validation_total |
| Passes | $validation_pass |
| Failures | $validation_fail |
| **Pass rate** | **$(if [[ $validation_total -gt 0 ]]; then echo "scale=1; $validation_pass * 100 / $validation_total" | bc 2>/dev/null || echo 0; else echo "N/A"; fi)%** |

## Handoff Quality

| Metric | Value |
|--------|-------|
| Total handoffs | $handoff_count |
| Synthetic fallbacks | $synthetic_count |
| Avg freeform length | $avg_freeform chars |

## Context Agent

| Metric | Value |
|--------|-------|
| Stuck detections | $stuck_detections |
| Skip directives | $directive_skip |
| Human review requests | $directive_review |

## Knowledge Index
- Entries: $knowledge_entries

## Success Criteria Checklist

- [ ] All 14 tasks completed: $(if [[ $tasks_done -eq 14 ]]; then echo "YES"; else echo "NO ($tasks_done/14)"; fi)
- [ ] Total retries < 5: $(if [[ $total_retries -lt 5 ]]; then echo "YES ($total_retries)"; else echo "NO ($total_retries)"; fi)
- [ ] Zero synthetic handoffs: $(if [[ $synthetic_count -eq 0 ]]; then echo "YES"; else echo "NO ($synthetic_count)"; fi)
- [ ] No stuck detections: $(if [[ $stuck_detections -eq 0 ]]; then echo "YES"; else echo "NO ($stuck_detections)"; fi)
- [ ] All freeform > 200 chars: $(echo "$freeform_lengths" | jq '[.[].length | select(. < 200)] | if length == 0 then "YES" else "NO (\(length) under 200)" end' 2>/dev/null || echo "N/A")
ENDMD

log "Report written to $OUTPUT_DIR/"
log "  report.json — machine-parseable metrics"
log "  report.md   — human-readable summary"

echo "$OUTPUT_DIR"
