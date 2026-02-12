#!/usr/bin/env bash
set -euo pipefail

# PURPOSE: Analyze Ralph test run artifacts and generate structured report.
# USAGE: ./test-harness/analyze.sh <workspace_path> [output_dir]
# OUTPUT: Creates report.json and report.md in the output directory.
#
# Metrics collected:
#   - Task completion (done/failed/skipped/pending counts)
#   - Iteration count and retries per task
#   - Per-iteration timing (from events.jsonl timestamps)
#   - Validation pass/fail rates, failure reasons, test counts
#   - Handoff quality (synthetic count, freeform length, field coverage, signal fields)
#   - Context agent: prompt sizes, prep duration, fallback rate, directives
#   - Knowledge index entries by category
#   - Git: commit count, test count growth

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
[[ -f "$WORKSPACE/.ralph/progress-log.json" ]] && cp "$WORKSPACE/.ralph/progress-log.json" "$OUTPUT_DIR/progress-log.json" || true
[[ -f "$WORKSPACE/.ralph/progress-log.md" ]] && cp "$WORKSPACE/.ralph/progress-log.md" "$OUTPUT_DIR/progress-log.md" || true

# --- Compute metrics ---
log "Computing metrics"

PLAN="$OUTPUT_DIR/plan-final.json"
EVENTS="$OUTPUT_DIR/events.jsonl"
HANDOFF_DIR="$OUTPUT_DIR/handoffs"
VALIDATION_DIR="$OUTPUT_DIR/validation"
STATE="$OUTPUT_DIR/state.json"
RALPH_LOG="$OUTPUT_DIR/ralph.log"

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

###############################################################################
# Per-iteration timing (from events.jsonl iteration_start/iteration_end pairs)
###############################################################################
iteration_timing="[]"
first_ts=""
last_ts=""
total_duration_s=0
if [[ -s "$EVENTS" ]]; then
    first_ts=$(head -1 "$EVENTS" | jq -r '.timestamp // empty' 2>/dev/null || echo "")
    last_ts=$(tail -1 "$EVENTS" | jq -r '.timestamp // empty' 2>/dev/null || echo "")

    # Build per-iteration timing from start/pass/fail events
    # Each iteration has iteration_start + (validation_pass|validation_fail|iteration_end)
    iteration_timing=$(jq -s '
        [.[] | select(.event == "iteration_start" or .event == "validation_pass" or .event == "validation_fail" or .event == "iteration_end")]
        | group_by(.metadata.iteration // 0)
        | map(select(.[0].metadata.iteration > 0))
        | map({
            iteration: .[0].metadata.iteration,
            task_id: .[0].metadata.task_id,
            task_title: (.[0].metadata.task_title // ""),
            start: (map(select(.event == "iteration_start")) | .[0].timestamp // null),
            end: (map(select(.event == "validation_pass" or .event == "validation_fail" or .event == "iteration_end")) | .[-1].timestamp // null),
            result: (if (map(select(.event == "validation_pass")) | length) > 0 then "pass"
                     elif (map(select(.event == "validation_fail")) | length) > 0 then "fail"
                     else "unknown" end)
        })
    ' "$EVENTS" 2>/dev/null || echo '[]')

    # Total wall-clock duration in seconds (macOS-compatible date arithmetic)
    if [[ -n "$first_ts" && -n "$last_ts" ]]; then
        if command -v gdate >/dev/null 2>&1; then
            start_epoch=$(gdate -d "$first_ts" +%s 2>/dev/null || echo 0)
            end_epoch=$(gdate -d "$last_ts" +%s 2>/dev/null || echo 0)
        else
            # macOS date -j
            start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$first_ts" +%s 2>/dev/null || echo 0)
            end_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" +%s 2>/dev/null || echo 0)
        fi
        total_duration_s=$(( end_epoch - start_epoch ))
    fi
fi

###############################################################################
# Validation metrics (expanded: per-check pass/fail + test counts from output)
###############################################################################
validation_pass=0
validation_fail=0
validation_errors="[]"
per_iteration_tests="[]"
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

    # Extract Jest test counts from validation output per iteration
    per_iteration_tests=$(
        for vfile in "$VALIDATION_DIR"/iter-*.json; do
            [[ -f "$vfile" ]] || continue
            iter_num=$(basename "$vfile" | sed 's/iter-//;s/\.json//')
            # Jest outputs "Tests: N passed, N total" and "Test Suites: N passed, N total"
            jest_output=$(jq -r '.checks[0].output // ""' "$vfile" 2>/dev/null || echo "")
            tests_total=$(echo "$jest_output" | grep -oE 'Tests:[[:space:]]+[0-9]+ passed, [0-9]+ total' | grep -oE '[0-9]+ total' | grep -oE '[0-9]+' || echo "0")
            suites_total=$(echo "$jest_output" | grep -oE 'Test Suites:[[:space:]]+[0-9]+ passed, [0-9]+ total' | grep -oE '[0-9]+ total' | grep -oE '[0-9]+' || echo "0")
            # Playwright outputs "N passed"
            pw_output=$(jq -r '.checks[2].output // ""' "$vfile" 2>/dev/null || echo "")
            pw_passed=$(echo "$pw_output" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo "0")
            echo "{\"iteration\":$iter_num,\"jest_tests\":${tests_total:-0},\"jest_suites\":${suites_total:-0},\"playwright_tests\":${pw_passed:-0}}"
        done | jq -s '.' 2>/dev/null || echo '[]'
    )
fi
validation_total=$((validation_pass + validation_fail))

###############################################################################
# Handoff metrics (expanded: signal fields, freeform quality)
###############################################################################
handoff_count=0
synthetic_count=0
freeform_lengths="[]"
field_coverage="[]"
signal_fields="[]"
avg_freeform=0
if [[ -d "$HANDOFF_DIR" ]]; then
    for hfile in "$HANDOFF_DIR"/handoff-*.json; do
        [[ -f "$hfile" ]] || continue
        handoff_count=$((handoff_count + 1))

        summary=$(jq -r '.summary // ""' "$hfile" 2>/dev/null || echo "")
        if [[ "$summary" == *"Synthetic handoff"* ]]; then
            synthetic_count=$((synthetic_count + 1))
        fi
    done

    # Freeform lengths
    freeform_lengths=$(
        for hfile in "$HANDOFF_DIR"/handoff-*.json; do
            [[ -f "$hfile" ]] || continue
            iter_num=$(basename "$hfile" | sed 's/handoff-0*//;s/\.json//')
            jq --arg iter "$iter_num" '{iteration: ($iter | tonumber), length: (.freeform // "" | length), is_synthetic: (.summary // "" | startswith("Synthetic"))}' "$hfile" 2>/dev/null
        done | jq -s '.' 2>/dev/null || echo '[]'
    )
    avg_freeform=$(echo "$freeform_lengths" | jq '[.[].length] | if length > 0 then (add / length | floor) else 0 end' 2>/dev/null || echo 0)

    # Structured field coverage
    field_coverage=$(
        for hfile in "$HANDOFF_DIR"/handoff-*.json; do
            [[ -f "$hfile" ]] || continue
            iter_num=$(basename "$hfile" | sed 's/handoff-0*//;s/\.json//')
            jq --arg iter "$iter_num" '{
                iteration: ($iter | tonumber),
                has_deviations: ((.deviations // []) | length > 0),
                has_bugs: ((.bugs_encountered // []) | length > 0),
                has_arch_notes: ((.architectural_notes // []) | length > 0),
                has_constraints: ((.constraints_discovered // []) | length > 0),
                has_files_touched: ((.files_touched // []) | length > 0),
                has_tests_added: ((.tests_added // []) | length > 0),
                has_recommendations: ((.recommendations // []) | length > 0),
                files_touched_count: ((.files_touched // []) | length),
                task_id_known: (.task_completed.task_id != "unknown" and .task_completed.task_id != null),
                fully_complete: (.task_completed.fully_complete // false)
            }' "$hfile" 2>/dev/null
        done | jq -s '.' 2>/dev/null || echo '[]'
    )

    # Signal fields — the feedback loop metrics
    signal_fields=$(
        for hfile in "$HANDOFF_DIR"/handoff-*.json; do
            [[ -f "$hfile" ]] || continue
            iter_num=$(basename "$hfile" | sed 's/handoff-0*//;s/\.json//')
            jq --arg iter "$iter_num" '{
                iteration: ($iter | tonumber),
                confidence: (.confidence_level // "absent"),
                research_requests: ((.request_research // []) | length),
                research_topics: (.request_research // []),
                human_review_needed: (.request_human_review.needed // false),
                human_review_reason: (.request_human_review.reason // null)
            }' "$hfile" 2>/dev/null
        done | jq -s '.' 2>/dev/null || echo '[]'
    )
fi

###############################################################################
# Context agent metrics (from ralph.log)
###############################################################################
context_prep_fallback_count=0
context_prep_json_count=0
prompt_sizes="[]"
if [[ -f "$RALPH_LOG" ]]; then
    # Count fallback vs structured directive returns
    context_prep_fallback_count=$(grep -c 'Context prep complete (fallback)' "$RALPH_LOG" 2>/dev/null || true)
    context_prep_fallback_count=${context_prep_fallback_count:-0}
    context_prep_json_count=$(grep -c 'Context prep complete:' "$RALPH_LOG" 2>/dev/null || true)
    context_prep_json_count=${context_prep_json_count:-0}

    # Extract prompt sizes (bytes and estimated tokens) per iteration
    prompt_sizes=$(
        grep -E 'Context prep complete.*prompt=' "$RALPH_LOG" 2>/dev/null | while IFS= read -r line; do
            bytes=$(echo "$line" | grep -oE 'prompt=[0-9]+' | grep -oE '[0-9]+' || echo "0")
            echo "{\"prompt_bytes\":$bytes}"
        done | jq -s 'to_entries | map({iteration: (.key + 1), prompt_bytes: .value.prompt_bytes})' 2>/dev/null || echo '[]'
    )
    # Also extract estimated token counts
    token_estimates=$(
        grep -E 'estimated tokens' "$RALPH_LOG" 2>/dev/null | while IFS= read -r line; do
            tokens=$(echo "$line" | grep -oE '[0-9]+ estimated tokens' | grep -oE '[0-9]+' || echo "0")
            echo "$tokens"
        done | jq -s 'to_entries | map({iteration: (.key + 1), estimated_tokens: .value})' 2>/dev/null || echo '[]'
    )
    # Merge prompt_sizes and token_estimates
    if [[ "$prompt_sizes" != "[]" && "$token_estimates" != "[]" ]]; then
        prompt_sizes=$(jq -s '
            .[0] as $sizes | .[1] as $tokens |
            [$sizes[] | . as $s | ($tokens[] | select(.iteration == $s.iteration)) as $t |
             $s + {estimated_tokens: ($t.estimated_tokens // null)}]
        ' <<< "$prompt_sizes
$token_estimates" 2>/dev/null || echo "$prompt_sizes")
    fi
fi

###############################################################################
# Event-based metrics
###############################################################################
stuck_detections=0
directive_skip=0
directive_review=0
failure_patterns="[]"
if [[ -s "$EVENTS" ]]; then
    stuck_detections=$(grep -c '"stuck_detected"' "$EVENTS" 2>/dev/null || true)
    stuck_detections=${stuck_detections:-0}
    directive_skip=$(grep -c '"skip_task"' "$EVENTS" 2>/dev/null || true)
    directive_skip=${directive_skip:-0}
    directive_review=$(grep -c '"human_review_requested"' "$EVENTS" 2>/dev/null || true)
    directive_review=${directive_review:-0}

    # Extract failure pattern events
    failure_patterns=$(jq -s '[.[] | select(.event == "failure_pattern" or .event == "validation_fail")]' "$EVENTS" 2>/dev/null || echo '[]')
fi

###############################################################################
# Knowledge index (expanded: by category)
###############################################################################
knowledge_entries=0
knowledge_by_category='{}'
if [[ -f "$OUTPUT_DIR/knowledge-index.md" ]]; then
    ki_file="$OUTPUT_DIR/knowledge-index.md"
    knowledge_decisions=$(grep -c '^\- \[K-decision-' "$ki_file" 2>/dev/null || true)
    knowledge_patterns=$(grep -c '^\- \[K-pattern-' "$ki_file" 2>/dev/null || true)
    knowledge_constraints=$(grep -c '^\- \[K-constraint-' "$ki_file" 2>/dev/null || true)
    knowledge_gotchas=$(grep -c '^\- \[K-gotcha-' "$ki_file" 2>/dev/null || true)
    knowledge_unresolved=$(grep -c '^\- \[K-unresolved-' "$ki_file" 2>/dev/null || true)
    knowledge_entries=$(( ${knowledge_decisions:-0} + ${knowledge_patterns:-0} + ${knowledge_constraints:-0} + ${knowledge_gotchas:-0} + ${knowledge_unresolved:-0} ))
    knowledge_by_category=$(jq -n \
        --argjson d "${knowledge_decisions:-0}" \
        --argjson p "${knowledge_patterns:-0}" \
        --argjson c "${knowledge_constraints:-0}" \
        --argjson g "${knowledge_gotchas:-0}" \
        --argjson u "${knowledge_unresolved:-0}" \
        '{decisions: $d, patterns: $p, constraints: $c, gotchas: $g, unresolved: $u}')
fi

###############################################################################
# Git metrics
###############################################################################
git_commits=0
if [[ -d "$WORKSPACE/.git" ]]; then
    git_commits=$( (cd "$WORKSPACE" && git rev-list --count HEAD) 2>/dev/null || echo 0)
fi

###############################################################################
# --- Generate report.json ---
###############################################################################
log "Generating report.json"
jq -n \
    --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg workspace "$WORKSPACE" \
    --argjson tasks_total "$tasks_total" \
    --argjson tasks_done "$tasks_done" \
    --argjson tasks_failed "$tasks_failed" \
    --argjson tasks_skipped "$tasks_skipped" \
    --argjson tasks_pending "$tasks_pending" \
    --argjson total_iterations "$total_iterations" \
    --arg final_status "$final_status" \
    --argjson total_retries "$total_retries" \
    --argjson retries_by_task "$retries_json" \
    --argjson iteration_timing "$iteration_timing" \
    --argjson total_duration_s "$total_duration_s" \
    --argjson validation_total "$validation_total" \
    --argjson validation_pass "$validation_pass" \
    --argjson validation_fail "$validation_fail" \
    --argjson validation_errors "$validation_errors" \
    --argjson per_iteration_tests "$per_iteration_tests" \
    --argjson handoff_count "$handoff_count" \
    --argjson synthetic_count "$synthetic_count" \
    --argjson avg_freeform "$avg_freeform" \
    --argjson freeform_lengths "$freeform_lengths" \
    --argjson field_coverage "$field_coverage" \
    --argjson signal_fields "$signal_fields" \
    --argjson prompt_sizes "$prompt_sizes" \
    --argjson context_prep_fallback "$context_prep_fallback_count" \
    --argjson context_prep_json "$context_prep_json_count" \
    --argjson stuck_detections "$stuck_detections" \
    --argjson directive_skip "$directive_skip" \
    --argjson directive_review "$directive_review" \
    --argjson failure_patterns "$failure_patterns" \
    --argjson knowledge_entries "$knowledge_entries" \
    --argjson knowledge_by_category "$knowledge_by_category" \
    --argjson git_commits "$git_commits" \
    --arg first_event "${first_ts:-}" \
    --arg last_event "${last_ts:-}" \
'{
    generated_at: $generated,
    workspace: $workspace,
    completion: {
        tasks_total: $tasks_total,
        tasks_done: $tasks_done,
        tasks_failed: $tasks_failed,
        tasks_skipped: $tasks_skipped,
        tasks_pending: $tasks_pending,
        completion_rate: (if $tasks_total > 0 then ($tasks_done * 100 / $tasks_total) else 0 end)
    },
    iterations: {
        total: $total_iterations,
        final_status: $final_status,
        total_retries: $total_retries,
        retries_by_task: $retries_by_task,
        per_iteration: $iteration_timing
    },
    timing: {
        first_event: $first_event,
        last_event: $last_event,
        total_duration_seconds: $total_duration_s,
        total_duration_human: (if $total_duration_s > 3600 then "\($total_duration_s / 3600 | floor)h \(($total_duration_s % 3600) / 60 | floor)m"
                               elif $total_duration_s > 60 then "\($total_duration_s / 60 | floor)m \($total_duration_s % 60)s"
                               else "\($total_duration_s)s" end)
    },
    validation: {
        total_runs: $validation_total,
        passes: $validation_pass,
        failures: $validation_fail,
        pass_rate: (if $validation_total > 0 then ($validation_pass * 100 / $validation_total) else 0 end),
        failure_details: $validation_errors,
        test_counts_per_iteration: $per_iteration_tests
    },
    handoffs: {
        total: $handoff_count,
        synthetic_count: $synthetic_count,
        structured_count: ($handoff_count - $synthetic_count),
        synthetic_rate: (if $handoff_count > 0 then ($synthetic_count * 100 / $handoff_count) else 0 end),
        avg_freeform_length: $avg_freeform,
        freeform_lengths: $freeform_lengths,
        field_coverage: $field_coverage,
        signal_fields: $signal_fields
    },
    context_agent: {
        stuck_detections: $stuck_detections,
        directives: { skip: $directive_skip, human_review: $directive_review },
        prep_fallback_count: $context_prep_fallback,
        prep_json_count: $context_prep_json,
        prep_fallback_rate: (if ($context_prep_fallback + $context_prep_json) > 0
                             then ($context_prep_fallback * 100 / ($context_prep_fallback + $context_prep_json))
                             else 0 end),
        prompt_sizes: $prompt_sizes,
        failure_patterns: $failure_patterns
    },
    knowledge: {
        total_entries: $knowledge_entries,
        by_category: $knowledge_by_category
    },
    git: { total_commits: $git_commits }
}' > "$OUTPUT_DIR/report.json"

###############################################################################
# --- Generate report.md ---
###############################################################################
log "Generating report.md"

# Pre-compute some values for the markdown
completion_rate=$(echo "scale=1; $tasks_done * 100 / $tasks_total" | bc 2>/dev/null || echo 0)
validation_rate=$(if [[ $validation_total -gt 0 ]]; then echo "scale=1; $validation_pass * 100 / $validation_total" | bc 2>/dev/null || echo 0; else echo "N/A"; fi)
synthetic_rate=$(if [[ $handoff_count -gt 0 ]]; then echo "scale=1; $synthetic_count * 100 / $handoff_count" | bc 2>/dev/null || echo 0; else echo 0; fi)
duration_human=""
if [[ $total_duration_s -gt 3600 ]]; then
    duration_human="$((total_duration_s / 3600))h $((total_duration_s % 3600 / 60))m"
elif [[ $total_duration_s -gt 60 ]]; then
    duration_human="$((total_duration_s / 60))m $((total_duration_s % 60))s"
else
    duration_human="${total_duration_s}s"
fi

cat > "$OUTPUT_DIR/report.md" <<ENDMD
# Ralph Pipeline Test Report

Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Workspace: \`$WORKSPACE\`
Duration: ${duration_human}

## Summary Dashboard

| Metric | Value | Target | Status |
|--------|-------|--------|--------|
| Tasks completed | $tasks_done/$tasks_total | 14/14 | $(if [[ $tasks_done -eq $tasks_total ]]; then echo "PASS"; else echo "FAIL"; fi) |
| Total retries | $total_retries | < 5 | $(if [[ $total_retries -lt 5 ]]; then echo "PASS"; else echo "FAIL"; fi) |
| Synthetic handoffs | $synthetic_count/$handoff_count (${synthetic_rate}%) | 0 | $(if [[ $synthetic_count -eq 0 ]]; then echo "PASS"; else echo "FAIL"; fi) |
| Stuck detections | $stuck_detections | 0 | $(if [[ $stuck_detections -eq 0 ]]; then echo "PASS"; else echo "FAIL"; fi) |
| Freeform > 200 chars | $(echo "$freeform_lengths" | jq '[.[].length | select(. >= 200)] | length' 2>/dev/null || echo 0)/$handoff_count | all | $(echo "$freeform_lengths" | jq 'if [.[].length | select(. < 200)] | length == 0 then "PASS" else "FAIL" end' 2>/dev/null || echo "N/A") |
| Validation pass rate | $validation_pass/$validation_total (${validation_rate}%) | 100% | $(if [[ $validation_fail -eq 0 ]]; then echo "PASS"; else echo "FAIL"; fi) |

## Per-Iteration Timeline

| Iter | Task | Result | Duration | Jest Tests | PW Tests | Freeform | Synthetic |
|------|------|--------|----------|------------|----------|----------|-----------|
$(echo "$iteration_timing" | jq -r --argjson tests "$per_iteration_tests" --argjson ff "$freeform_lengths" '
    .[] | . as $it |
    ($tests | map(select(.iteration == $it.iteration)) | .[0] // {jest_tests: "?", playwright_tests: "?"}) as $t |
    ($ff | map(select(.iteration == $it.iteration)) | .[0] // {length: "?", is_synthetic: true}) as $f |
    "| \($it.iteration) | \($it.task_id) | \($it.result) | — | \($t.jest_tests) | \($t.playwright_tests) | \($f.length)ch | \(if $f.is_synthetic then "yes" else "no" end) |"
' 2>/dev/null || echo "| — | — | — | — | — | — | — | — |")

## Handoff Quality

| Metric | Value |
|--------|-------|
| Total handoffs | $handoff_count |
| Synthetic fallbacks | $synthetic_count (${synthetic_rate}%) |
| Structured (with JSON) | $((handoff_count - synthetic_count)) |
| Avg freeform length | $avg_freeform chars |
| Min freeform length | $(echo "$freeform_lengths" | jq '[.[].length] | min // 0' 2>/dev/null || echo 0) chars |
| Max freeform length | $(echo "$freeform_lengths" | jq '[.[].length] | max // 0' 2>/dev/null || echo 0) chars |

### Feedback Loop (Signal Fields)

| Iter | Confidence | Research Requests | Human Review |
|------|-----------|-------------------|-------------|
$(echo "$signal_fields" | jq -r '.[] | "| \(.iteration) | \(.confidence) | \(.research_requests) | \(.human_review_needed) |"' 2>/dev/null || echo "| — | — | — | — |")

### Structured Field Coverage

| Iter | task_id known | files_touched | tests_added | deviations | constraints | arch_notes |
|------|--------------|---------------|-------------|------------|-------------|------------|
$(echo "$field_coverage" | jq -r '.[] | "| \(.iteration) | \(.task_id_known) | \(.has_files_touched) | \(.has_tests_added) | \(.has_deviations) | \(.has_constraints) | \(.has_arch_notes) |"' 2>/dev/null || echo "| — | — | — | — | — | — | — |")

## Context Agent

| Metric | Value |
|--------|-------|
| Prep fallback (text→default) | $context_prep_fallback_count |
| Prep structured (JSON) | $context_prep_json_count |
| Fallback rate | $(if [[ $((context_prep_fallback_count + context_prep_json_count)) -gt 0 ]]; then echo "scale=0; $context_prep_fallback_count * 100 / ($context_prep_fallback_count + $context_prep_json_count)" | bc 2>/dev/null || echo 0; else echo 0; fi)% |
| Stuck detections | $stuck_detections |
| Skip directives | $directive_skip |
| Human review requests | $directive_review |

### Prompt Size Growth

$(echo "$prompt_sizes" | jq -r 'if length > 0 then
    "| Iter | Prompt Bytes | Est. Tokens |\n|------|-------------|-------------|\n" +
    (.[] | "| \(.iteration) | \(.prompt_bytes) | \(.estimated_tokens // "?") |")
else "No prompt size data available." end' 2>/dev/null || echo "No prompt size data available.")

## Knowledge Index

| Category | Count |
|----------|-------|
| Decisions | ${knowledge_decisions:-0} |
| Patterns | ${knowledge_patterns:-0} |
| Constraints | ${knowledge_constraints:-0} |
| Gotchas | ${knowledge_gotchas:-0} |
| Unresolved | ${knowledge_unresolved:-0} |
| **Total** | **$knowledge_entries** |

## Validation Detail

| Metric | Value |
|--------|-------|
| Total runs | $validation_total |
| Passes | $validation_pass |
| Failures | $validation_fail |
| Pass rate | ${validation_rate}% |

### Test Count Growth

$(echo "$per_iteration_tests" | jq -r 'if length > 0 then
    "| Iter | Jest Tests | Jest Suites | Playwright Tests |\n|------|-----------|-------------|------------------|\n" +
    (.[] | "| \(.iteration) | \(.jest_tests) | \(.jest_suites) | \(.playwright_tests) |")
else "No test count data." end' 2>/dev/null || echo "No test count data.")

## Git

- Total commits in workspace: $git_commits

## Success Criteria Checklist

- [$(if [[ $tasks_done -eq $tasks_total ]]; then echo "x"; else echo " "; fi)] All $tasks_total tasks completed: $(if [[ $tasks_done -eq $tasks_total ]]; then echo "YES"; else echo "NO ($tasks_done/$tasks_total)"; fi)
- [$(if [[ $total_retries -lt 5 ]]; then echo "x"; else echo " "; fi)] Total retries < 5: $(if [[ $total_retries -lt 5 ]]; then echo "YES ($total_retries)"; else echo "NO ($total_retries)"; fi)
- [$(if [[ $synthetic_count -eq 0 ]]; then echo "x"; else echo " "; fi)] Zero synthetic handoffs: $(if [[ $synthetic_count -eq 0 ]]; then echo "YES"; else echo "NO ($synthetic_count/$handoff_count)"; fi)
- [$(if [[ $stuck_detections -eq 0 ]]; then echo "x"; else echo " "; fi)] No stuck detections: $(if [[ $stuck_detections -eq 0 ]]; then echo "YES"; else echo "NO ($stuck_detections)"; fi)
- [$(echo "$freeform_lengths" | jq -r 'if [.[].length | select(. < 200)] | length == 0 then "x" else " " end' 2>/dev/null || echo " ")] All freeform > 200 chars: $(echo "$freeform_lengths" | jq -r '[.[].length | select(. < 200)] | if length == 0 then "YES" else "NO (\(length) under 200)" end' 2>/dev/null || echo "N/A")
ENDMD

log "Report written to $OUTPUT_DIR/"
log "  report.json — machine-parseable metrics"
log "  report.md   — human-readable summary"

echo "$OUTPUT_DIR"
