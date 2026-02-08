#!/usr/bin/env bash
set -euo pipefail

# context.sh — Prompt assembly and context engineering for coding iterations
#
# MODULE PURPOSE IN ORCHESTRATOR FLOW:
# - This module turns plan/task state + prior handoff artifacts into the coding prompt
#   consumed by the LLM in ralph.sh run_coding_cycle().
# - It also enforces context-budget behavior through section-aware truncation so the
#   orchestrator preserves high-value context first when prompts are too large.
# - It supports both operating modes:
#   - handoff-only: short-term memory is the previous handoff freeform narrative only.
#   - handoff-plus-index: includes narrative + structured retrieval from knowledge index.
#
# KEY EXPORTED FUNCTIONS:
# - build_coding_prompt_v2(task_json, mode, skills_content, failure_context): primary
#   prompt constructor used in normal operation.
# - truncate_to_budget(content, budget_tokens): post-assembly trimmer that preserves
#   parser-visible section structure and emits truncation metadata.
# - get_prev_handoff_for_mode(handoffs_dir, mode): mode-sensitive previous handoff
#   retrieval used by v2 prompt assembly.
# - retrieve_relevant_knowledge(task_json, index_file, max_lines): targeted knowledge
#   lookup for handoff-plus-index mode.
# - Legacy compatibility helpers kept for v1 fallback:
#   load_skills(), get_prev_handoff_summary(), get_earlier_l1_summaries(),
#   format_compacted_context(), build_coding_prompt().
#
# INPUTS / OUTPUTS / CRITICAL INVARIANTS:
# - Inputs: task JSON, mode flag, failure context text, optional compacted context,
#   files under .ralph/handoffs/, .ralph/knowledge-index.md, .ralph/skills/, and
#   .ralph/templates/coding-prompt-footer.md.
# - Outputs: markdown prompt text for LLM submission; when truncating, also emits a
#   trailing [[TRUNCATION_METADATA]] JSON line for tests/debugging.
# - Invariants:
#   - Prompt section headers used by v2 truncation are parser-sensitive literals.
#   - Header names and order must stay aligned between build_coding_prompt_v2() and
#     truncate_to_budget() awk matching logic.
#   - Previous handoff retrieval is mode-sensitive by design and must preserve
#     handoff-only vs handoff-plus-index behavior differences.
#
# PARSER-SENSITIVE CONSTRAINTS:
# - Do not rename any of these v2 headers without updating truncation/retrieval logic
#   that matches them literally via awk: 
#   "## Current Task", "## Failure Context", "## Retrieved Memory",
#   "## Previous Handoff", "## Retrieved Project Memory",
#   "## Accumulated Knowledge", "## Skills", "## Output Instructions".
# - These literals are consumed by truncation parsing; changing them silently degrades
#   budget enforcement behavior.
#
# DEPENDENCIES:
#   Called by: ralph.sh run_coding_cycle() (build_coding_prompt_v2, truncate_to_budget,
#             estimate_tokens, load_skills, get_prev_handoff_summary, get_earlier_l1_summaries,
#             format_compacted_context)
#   Depends on: jq, awk, log() from ralph.sh
#   Reads files: .ralph/handoffs/handoff-NNN.json (most recent),
#                .ralph/knowledge-index.md (in handoff-plus-index mode),
#                .ralph/templates/coding-prompt-footer.md (output instructions),
#                .ralph/skills/*.md (per-task skill files)
#   Globals read: RALPH_CONTEXT_BUDGET_TOKENS (default 8000)
#
# THE 8-SECTION PROMPT (build_coding_prompt_v2):
#   Assembled in this exact order. Section headers are "## Name" — truncation
#   relies on these being exact matches. Do not rename without updating awk parser.
#
#   1. ## Current Task         — always present, from plan.json task object
#   2. ## Failure Context      — retry iterations only, from validation output
#   3. ## Retrieved Memory     — constraints + decisions from latest handoff
#   4. ## Previous Handoff     — freeform narrative (± L2 in h+i mode)
#   5. ## Retrieved Project Memory — h+i mode only, keyword-matched from index
#   6. ## Accumulated Knowledge — h+i mode only, pointer to knowledge-index.md
#   7. ## Skills               — task-specific skill files from .ralph/skills/
#   8. ## Output Instructions  — from template or inline fallback
#
# TRUNCATION PRIORITY (lowest number = trimmed first):
#   1. Accumulated Knowledge (just a pointer — removed entirely)
#   2. Skills (trimmed from end)
#   3. Output Instructions (trimmed from end, min 22 chars kept)
#   4. Previous Handoff (trimmed from end, min 18 chars kept)
#   5. Retrieved Project Memory (trimmed from end)
#   6. Retrieved Memory (trimmed from end, min 17 chars kept)
#   7. Failure Context (trimmed from end)
#   8. Current Task (last resort — hard truncate)

# Source config if not already loaded
if [[ -z "${RALPH_CONTEXT_BUDGET_TOKENS:-}" ]]; then
    RALPH_CONTEXT_BUDGET_TOKENS=8000
fi

# log() stub for standalone testing — ralph.sh provides the real one
if ! declare -f log >/dev/null 2>&1; then
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2" >&2; }
fi

# Approximate token count via chars / 4.
# This is a rough heuristic used for budget decisions, not billing.
estimate_tokens() {
    local text="$1"
    echo $(( ${#text} / 4 ))
}

# Section-aware truncation for v2 prompts.
#
# HOW IT WORKS:
# 1. If content fits budget, pass through unchanged.
# 2. Split content into 8 named sections using awk on "## " headers.
# 3. Trim sections in priority order (Accumulated Knowledge first, Current Task last).
# 4. Rebuild prompt from sections after each trim, re-check size.
# 5. Emit [[TRUNCATION_METADATA]] JSON at end (consumed by tests, not by Claude).
#
# CRITICAL: The awk parser matches EXACT header text (e.g., "^## Current Task$").
# If section headers in build_coding_prompt_v2() change, this parser MUST be updated.
#
# Args: $1 = content, $2 = budget_tokens (optional, default RALPH_CONTEXT_BUDGET_TOKENS)
# Stdout: truncated content + truncation metadata
# Caller: ralph.sh run_coding_cycle() after prompt assembly.
# Side effects: none on disk; CPU-only string processing and writes result to stdout.
# Why-specific behavior: trims by semantic sections to preserve high-value context and
# parser-visible structure, rather than doing a blind tail cut that would drop task intent.
truncate_to_budget() {
    local content="$1"
    local budget_tokens="${2:-${RALPH_CONTEXT_BUDGET_TOKENS}}"
    local max_chars=$(( budget_tokens * 4 ))

    local current_chars=${#content}
    if [[ "$current_chars" -le "$max_chars" ]]; then
        echo "$content"
        return
    fi

    # Section-aware truncation for v2 prompts.
    if [[ "$content" == *"## Current Task"* && "$content" == *"## Output Instructions"* ]]; then
        local current_task failure_context retrieved_memory previous_handoff retrieved_project_memory accumulated_knowledge skills output_instructions

        # Single awk pass splits content into named sections.
        # Section boundaries are ^## headers matching the exact 8 section names.
        local _sections
        _sections="$(echo "$content" | awk '
            BEGIN { current="" }
            /^## Current Task$/           { current="CURRENT_TASK"; next }
            /^## Failure Context$/        { current="FAILURE_CONTEXT"; next }
            /^## Retrieved Memory$/       { current="RETRIEVED_MEMORY"; next }
            /^## Previous Handoff$/       { current="PREVIOUS_HANDOFF"; next }
            /^## Retrieved Project Memory$/ { current="RETRIEVED_PROJECT_MEMORY"; next }
            /^## Accumulated Knowledge$/  { current="ACCUMULATED_KNOWLEDGE"; next }
            /^## Skills$/                 { current="SKILLS"; next }
            /^## Output Instructions$/    { current="OUTPUT_INSTRUCTIONS"; next }
            current != "" { print current "\t" $0 }
        ')"

        _extract_section() {
            local tag="$1"
            echo "$_sections" | awk -F'\t' -v t="$tag" '$1 == t { sub(/^[^\t]*\t/, ""); print }'
        }

        current_task="$(_extract_section "CURRENT_TASK")"
        failure_context="$(_extract_section "FAILURE_CONTEXT")"
        retrieved_memory="$(_extract_section "RETRIEVED_MEMORY")"
        previous_handoff="$(_extract_section "PREVIOUS_HANDOFF")"
        retrieved_project_memory="$(_extract_section "RETRIEVED_PROJECT_MEMORY")"
        accumulated_knowledge="$(_extract_section "ACCUMULATED_KNOWLEDGE")"
        skills="$(_extract_section "SKILLS")"
        output_instructions="$(_extract_section "OUTPUT_INSTRUCTIONS")"

        local truncated_sections=()
        local rebuilt over trim_by

        _rebuild_prompt() {
            local r=""
            r+="## Current Task"$'\n'"${current_task}"
            r+=$'\n\n'"## Failure Context"$'\n'"${failure_context}"
            r+=$'\n\n'"## Retrieved Memory"$'\n'"${retrieved_memory}"
            r+=$'\n\n'"## Previous Handoff"$'\n'"${previous_handoff}"
            if [[ -n "$retrieved_project_memory" ]]; then
                r+=$'\n\n'"## Retrieved Project Memory"$'\n'"${retrieved_project_memory}"
            fi
            if [[ -n "$accumulated_knowledge" ]]; then
                r+=$'\n\n'"## Accumulated Knowledge"$'\n'"${accumulated_knowledge}"
            fi
            r+=$'\n\n'"## Skills"$'\n'"${skills}"
            r+=$'\n\n'"## Output Instructions"$'\n'"${output_instructions}"
            echo "$r"
        }

        rebuilt="$(_rebuild_prompt)"

        # Iteratively trim sections in priority order until within budget
        while [[ ${#rebuilt} -gt $max_chars ]]; do
            over=$(( ${#rebuilt} - max_chars ))

            if [[ -n "$accumulated_knowledge" && ${#accumulated_knowledge} -gt 2 ]]; then
                accumulated_knowledge=""
                [[ " ${truncated_sections[*]} " == *" Accumulated Knowledge "* ]] || truncated_sections+=("Accumulated Knowledge")
            elif [[ -n "$skills" && ${#skills} -gt 10 ]]; then
                trim_by=$(( over < ${#skills} - 10 ? over : ${#skills} - 10 ))
                skills="${skills:0:$(( ${#skills} - trim_by ))}"
                [[ " ${truncated_sections[*]} " == *" Skills "* ]] || truncated_sections+=("Skills")
            elif [[ -n "$output_instructions" && ${#output_instructions} -gt 22 ]]; then
                trim_by=$(( over < ${#output_instructions} - 22 ? over : ${#output_instructions} - 22 ))
                output_instructions="${output_instructions:0:$(( ${#output_instructions} - trim_by ))}"
                [[ " ${truncated_sections[*]} " == *" Output Instructions "* ]] || truncated_sections+=("Output Instructions")
            elif [[ -n "$previous_handoff" && ${#previous_handoff} -gt 18 ]]; then
                trim_by=$(( over < ${#previous_handoff} - 18 ? over : ${#previous_handoff} - 18 ))
                previous_handoff="${previous_handoff:0:$(( ${#previous_handoff} - trim_by ))}"
                [[ " ${truncated_sections[*]} " == *" Previous Handoff "* ]] || truncated_sections+=("Previous Handoff")
            elif [[ -n "$retrieved_project_memory" && ${#retrieved_project_memory} -gt 2 ]]; then
                trim_by=$(( over < ${#retrieved_project_memory} - 2 ? over : ${#retrieved_project_memory} - 2 ))
                retrieved_project_memory="${retrieved_project_memory:0:$(( ${#retrieved_project_memory} - trim_by ))}"
                [[ " ${truncated_sections[*]} " == *" Retrieved Project Memory "* ]] || truncated_sections+=("Retrieved Project Memory")
            elif [[ -n "$retrieved_memory" && ${#retrieved_memory} -gt 17 ]]; then
                trim_by=$(( over < ${#retrieved_memory} - 17 ? over : ${#retrieved_memory} - 17 ))
                retrieved_memory="${retrieved_memory:0:$(( ${#retrieved_memory} - trim_by ))}"
                [[ " ${truncated_sections[*]} " == *" Retrieved Memory "* ]] || truncated_sections+=("Retrieved Memory")
            elif [[ -n "$failure_context" && ${#failure_context} -gt 16 ]]; then
                trim_by=$(( over < ${#failure_context} - 16 ? over : ${#failure_context} - 16 ))
                failure_context="${failure_context:0:$(( ${#failure_context} - trim_by ))}"
                [[ " ${truncated_sections[*]} " == *" Failure Context "* ]] || truncated_sections+=("Failure Context")
            else
                # Last-resort: hard truncate from end, preserving task ID/title at the beginning
                rebuilt="${rebuilt:0:$max_chars}"
                [[ " ${truncated_sections[*]} " == *" Current Task "* ]] || truncated_sections+=("Current Task")
                break
            fi

            rebuilt="$(_rebuild_prompt)"
        done

        local trunc_json
        trunc_json=$(printf '%s\n' "${truncated_sections[@]}" | jq -R . | jq -s --argjson max_chars "$max_chars" --argjson original_chars "$current_chars" '{truncated_sections: ., max_chars: $max_chars, original_chars: $original_chars}')
        echo "$rebuilt"
        echo ""
        echo "[[TRUNCATION_METADATA]] ${trunc_json}"
        return
    fi

    echo "${content:0:$max_chars}"
    echo ""
    echo "[[TRUNCATION_METADATA]] {\"truncated_sections\":[\"unstructured\"],\"max_chars\":${max_chars},\"original_chars\":${current_chars}}"
}

# Read and concatenate skill files based on task's skills[] array.
# Skill files live in .ralph/skills/<name>.md and are injected into ## Skills.
# Args: $1 = task JSON, $2 = skills directory path
# Stdout: concatenated skill file contents
# Caller: ralph.sh run_coding_cycle() and legacy v1/v2 prompt construction paths.
# Side effects: reads markdown files from skills_dir; emits warn logs for missing files.
# Why-specific behavior: missing skills are non-fatal so task execution continues with
# best-effort conventions instead of hard-failing prompt assembly.
load_skills() {
    local task_json="$1"
    local skills_dir="${2:-.ralph/skills}"
    local combined=""

    for skill in $(echo "$task_json" | jq -r '.skills // [] | .[]'); do
        local skill_file="${skills_dir}/${skill}.md"
        if [[ -f "$skill_file" ]]; then
            combined+="$(cat "$skill_file")"$'\n\n'
        else
            log "warn" "Skill file not found: ${skill_file}"
        fi
    done
    echo "$combined"
}

# Extract L2 summary (decisions object) from most recent handoff JSON.
# Used by legacy v1 prompt builder; v2 uses get_prev_handoff_for_mode() instead.
# Args: $1 = handoffs directory
# Stdout: JSON object with task, decisions, deviations, constraints, failed, unfinished
get_prev_handoff_summary() {
    local handoffs_dir="${1:-.ralph/handoffs}"

    local latest
    latest=$(ls -1 "${handoffs_dir}"/handoff-*.json 2>/dev/null | sort -V | tail -1)

    if [[ -z "$latest" ]]; then
        echo ""
        return
    fi

    jq -r '{
        task: .task_completed.task_id,
        decisions: .architectural_notes,
        deviations: [.deviations[] | "\(.planned) → \(.actual): \(.reason)"],
        constraints: [.constraints_discovered[] | "\(.constraint): \(.workaround // .impact)"],
        failed: [.bugs_encountered[] | select(.resolved == false) | .description],
        unfinished: [.unfinished_business[] | "\(.item) (\(.priority))"]
    }' "$latest"
}

# Return context from the latest handoff, varying by operating mode.
#
# WHY MODE MATTERS:
# - handoff-only: The freeform narrative IS the sole memory artifact. No index exists,
#   so we give the full narrative without structured supplements.
# - handoff-plus-index: The narrative leads, but we also append structured L2 data
#   (deviations, constraints, decisions) because the knowledge index handles long-term
#   memory, freeing the handoff to focus on recent tactical context.
#
# Args: $1 = handoffs directory, $2 = mode ("handoff-only" or "handoff-plus-index")
# Stdout: formatted context string for ## Previous Handoff section
# CRITICAL: build_coding_prompt_v2() must pass $mode variable, not a hardcoded string.
# Caller: build_coding_prompt_v2() for the parser-sensitive "## Previous Handoff" section.
# Side effects: reads latest .ralph/handoffs/handoff-*.json; no filesystem writes.
# Why-specific behavior: mode determines memory shape—handoff-only preserves pure narrative,
# while handoff-plus-index appends compact structured L2 context for tactical recall.
get_prev_handoff_for_mode() {
    local handoffs_dir="${1:-.ralph/handoffs}"
    local mode="${2:-handoff-only}"

    local latest
    latest=$(ls -1 "${handoffs_dir}"/handoff-*.json 2>/dev/null | sort -V | tail -1)

    if [[ -z "$latest" ]]; then
        echo ""
        return
    fi

    case "$mode" in
        handoff-only)
            # Return the full freeform narrative — this IS the memory
            jq -r '.freeform // empty' "$latest"
            ;;
        handoff-plus-index)
            # Return freeform + structured L2 for richer tactical context
            local narrative
            narrative=$(jq -r '.freeform // ""' "$latest")
            local l2
            l2=$(jq -r '{
                task: .task_completed.task_id,
                decisions: .architectural_notes,
                constraints: [.constraints_discovered[] | "\(.constraint): \(.workaround // .impact)"]
            }' "$latest")
            echo "${narrative}"
            echo ""
            echo "### Structured context from previous iteration"
            echo "${l2}"
            ;;
        *)
            log "warn" "Unknown mode '${mode}' in get_prev_handoff_for_mode; falling back to handoff-only"
            jq -r '.freeform // empty' "$latest"
            ;;
    esac
}

# Get L1 summaries from the 2nd and 3rd most recent handoffs.
# Provides lightweight historical context beyond the immediate previous iteration.
# Used by legacy v1 prompt builder only.
# Args: $1 = handoffs directory
# Stdout: bulleted list of L1 summaries (via extract_l1 from compaction.sh)
get_earlier_l1_summaries() {
    local handoffs_dir="${1:-.ralph/handoffs}"

    # Sort newest-first, skip the most recent (covered by L2), take next 2
    local files
    files=$(ls -1 "${handoffs_dir}"/handoff-*.json 2>/dev/null | sort -Vr | tail -n +2 | head -2)

    if [[ -z "$files" ]]; then
        echo ""
        return
    fi

    local summaries=""
    while IFS= read -r f; do
        if [[ -n "$f" && -f "$f" ]]; then
            local l1
            l1=$(extract_l1 "$f")
            if [[ -n "$l1" ]]; then
                summaries+="- ${l1}"$'\n'
            fi
        fi
    done <<< "$files"

    echo "$summaries"
}

# Transform compacted context JSON into markdown sections for v1 prompt.
# Used by legacy build_coding_prompt() only.
# Args: $1 = compacted context JSON file path
# Stdout: formatted markdown sections
# Caller: legacy build_coding_prompt() only.
# Side effects: reads compacted context JSON file.
# Why-specific behavior: renders stable subsection labels expected by older fixtures/tests.
format_compacted_context() {
    local compacted_file="$1"

    if [[ ! -f "$compacted_file" ]]; then
        echo ""
        return
    fi

    echo "### Project State"
    jq -r '.project_summary' "$compacted_file"
    echo ""

    echo "### Completed Work"
    jq -r '.completed_work[] | "- " + .' "$compacted_file"
    echo ""

    echo "### Active Constraints (DO NOT VIOLATE)"
    jq -r '.active_constraints[] | "- " + .constraint' "$compacted_file"
    echo ""

    echo "### Architecture Decisions (Follow These)"
    jq -r '.architectural_decisions[] | "- " + .' "$compacted_file"
    echo ""

    if jq -e '.library_docs | length > 0' "$compacted_file" >/dev/null 2>&1; then
        echo "### Library Reference"
        jq -r '.library_docs[] | "**\(.library)**: \(.key_apis)\n\(.usage_notes // "")\n"' "$compacted_file"
    fi
}

# Pull a bounded set of relevant knowledge entries from the knowledge index.
# Used in handoff-plus-index mode to inject task-relevant context.
#
# HOW RELEVANCE WORKS:
# 1. Extract keywords from task id, title, description, and libraries array
# 2. Search knowledge-index.md via awk, matching keywords against each line
# 3. Lines are tagged by their category heading (Constraints, Patterns, etc.)
# 4. Results sorted by category priority, then line order
# 5. Max 12 lines returned (configurable via $3)
#
# CATEGORY PRIORITY (lower = more important):
#   Constraints (1) > Architectural Decisions (2) > Unresolved (3) > Gotchas (4) > Patterns (5)
#
# Args: $1 = task JSON, $2 = index file path, $3 = max lines (default 12)
# Stdout: matched knowledge lines, priority-sorted
# CALLER: build_coding_prompt_v2() for ## Retrieved Project Memory section
# Side effects: reads knowledge index file; no writes.
# Why-specific behavior: category-priority sorting front-loads constraints/decisions so
# truncation pressure is less likely to remove safety-critical project memory first.
retrieve_relevant_knowledge() {
    local task_json="$1"
    local index_file="${2:-.ralph/knowledge-index.md}"
    local max_lines="${3:-12}"

    if [[ ! -f "$index_file" ]]; then
        echo ""
        return
    fi

    # Build comma-separated search terms from task metadata
    local task_id task_title task_description terms_csv
    task_id=$(echo "$task_json" | jq -r '.id // ""')
    task_title=$(echo "$task_json" | jq -r '.title // ""')
    task_description=$(echo "$task_json" | jq -r '.description // ""')

    terms_csv=$(echo "$task_json" | jq -r --arg title "$task_title" --arg desc "$task_description" --arg id "$task_id" '
        [
            ($id | ascii_downcase),
            (.libraries // [] | .[]? | ascii_downcase),
            (($title + " " + $desc)
                | ascii_downcase
                | gsub("[^a-z0-9 ]"; " ")
                | split(" ")
                | map(select(length >= 4))
                | .[])
        ]
        | map(select(length > 0))
        | unique
        | .[0:40]
        | join(",")
    ')

    if [[ -z "$terms_csv" ]]; then
        echo ""
        return
    fi

    # Search index file: match lines containing any search term,
    # output with category priority and line number for sorting
    awk -v terms="$terms_csv" '
        BEGIN {
            split(terms, raw_terms, ",");
            for (i in raw_terms) {
                if (length(raw_terms[i]) > 0) query[raw_terms[i]] = 1;
            }

            priority["constraints"] = 1;
            priority["architectural decisions"] = 2;
            priority["unresolved"] = 3;
            priority["gotchas"] = 4;
            priority["patterns"] = 5;
            current = "";
        }
        /^##[[:space:]]+/ {
            heading = tolower($0);
            sub(/^##[[:space:]]+/, "", heading);
            gsub(/[[:space:]]+$/, "", heading);
            current = heading;
            next;
        }
        {
            if (current == "" || !(current in priority)) next;

            line = $0;
            if (line ~ /^[[:space:]]*$/) next;

            low = tolower(line);
            matched = 0;
            for (term in query) {
                if (index(low, term) > 0) {
                    matched = 1;
                    break;
                }
            }

            if (matched) {
                printf "%d\t%d\t%s\n", priority[current], NR, line;
            }
        }
    ' "$index_file" | sort -t $'\t' -k1,1n -k2,2n | cut -f3- | head -n "$max_lines"
}

# build_coding_prompt_v2 — Mode-aware prompt assembly (8 sections)
#
# This is the primary prompt builder. It assembles all context the coding LLM
# needs for an iteration, organized into 8 named sections that the truncation
# engine can independently trim.
#
# CRITICAL INVARIANTS:
# - Section headers must be exactly "## Name" (awk parser in truncate_to_budget matches these)
# - Section order must match truncation priority expectations
# - $mode must be passed as a variable, not hardcoded (tests verify this)
# - In handoff-only mode, sections 5 and 6 are omitted (no knowledge index)
#
# Args: $1 = task JSON, $2 = mode, $3 = skills content, $4 = failure context
# Stdout: assembled prompt ready for truncation and CLI submission
# CALLER: ralph.sh run_coding_cycle() (behind declare -f guard for v1 fallback)
# Side effects: reads latest handoff JSON, knowledge index, and output-footer template;
# does not write files.
# Why-specific behavior: keeps exact "##" header literals and order aligned with
# truncate_to_budget() so section-aware parsing/trimming stays deterministic.
build_coding_prompt_v2() {
    local task_json="$1"
    local mode="${2:-handoff-only}"
    local skills_content="$3"
    local failure_context="$4"

    local base_dir="${RALPH_DIR:-.ralph}"
    local handoffs_dir="${base_dir}/handoffs"
    local prompt=""

    local task_section
    task_section="$(echo "$task_json" | jq -r '"## Current Task\nID: \(.id)\nTitle: \(.title)\n\nDescription:\n\(.description)\n\nAcceptance Criteria:\n" + ((.acceptance_criteria // []) | map("- " + .) | join("\n"))')"

    local failure_section="## Failure Context
No failure context."
    if [[ -n "$failure_context" ]]; then
        failure_section="## Failure Context
${failure_context}"
    fi

    # Retrieved Memory: constraints + decisions from the latest handoff
    local retrieved_memory_section="## Retrieved Memory
No retrieved memory available."
    local latest_handoff
    latest_handoff=$(ls -1 "${handoffs_dir}"/handoff-*.json 2>/dev/null | sort -V | tail -1 || true)
    if [[ -n "$latest_handoff" ]]; then
        local constraints decisions
        constraints=$(jq -r '[.constraints_discovered[]? | "- " + .constraint + ": " + (.workaround // .impact // "no workaround recorded")] | join("\n")' "$latest_handoff")
        decisions=$(jq -r '[.architectural_notes[]? | "- " + .] | join("\n")' "$latest_handoff")
        retrieved_memory_section="## Retrieved Memory
### Constraints
${constraints:-No constraints recorded.}

### Decisions
${decisions:-No decisions recorded.}"
        # In h+i mode, also point to the knowledge index
        if [[ "$mode" == "handoff-plus-index" && -f "${base_dir}/knowledge-index.md" ]]; then
            retrieved_memory_section+=$'\n\n### Knowledge Index\n- .ralph/knowledge-index.md'
        fi
    fi

    # Previous Handoff: mode-sensitive (freeform only vs freeform + L2)
    local narrative
    narrative="$(get_prev_handoff_for_mode "$handoffs_dir" "$mode")"
    local previous_handoff_section="## Previous Handoff
This is the first iteration. No previous handoff available."
    if [[ -n "$narrative" ]]; then
        previous_handoff_section="## Previous Handoff
${narrative}"
    fi

    # Retrieved Project Memory: keyword-matched entries (handoff-plus-index only)
    local retrieved_project_memory_section=""
    if [[ "$mode" == "handoff-plus-index" && -f "${base_dir}/knowledge-index.md" ]]; then
        local retrieved_project_memory
        retrieved_project_memory="$(retrieve_relevant_knowledge "$task_json" "${base_dir}/knowledge-index.md" 12)"
        if [[ -n "$retrieved_project_memory" ]]; then
            retrieved_project_memory_section="## Retrieved Project Memory
${retrieved_project_memory}"
        fi
    fi

    # Accumulated Knowledge: static pointer (handoff-plus-index only, lowest truncation priority)
    local accumulated_knowledge_section=""
    if [[ "$mode" == "handoff-plus-index" && -f "${base_dir}/knowledge-index.md" ]]; then
        accumulated_knowledge_section="## Accumulated Knowledge
A knowledge index of learnings from all previous iterations is available at .ralph/knowledge-index.md. Consult it if you need project history beyond what's in the handoff above."
    fi

    local skills_section="## Skills
No specific skills loaded."
    if [[ -n "$skills_content" ]]; then
        skills_section="## Skills
${skills_content}"
    fi

    # Output Instructions: loaded from template file, with inline fallback
    local output_instructions
    output_instructions="$(cat "${base_dir}/templates/coding-prompt-footer.md" 2>/dev/null)" || true
    if [[ -z "$output_instructions" ]]; then
        output_instructions="$(cat "${base_dir}/templates/coding-prompt.md" 2>/dev/null)" || true
    fi
    if [[ -z "$output_instructions" ]]; then
        output_instructions="## When You're Done

After completing your implementation and verifying the acceptance criteria,
write a handoff for whoever picks up this project next.

Your output must be valid JSON matching the provided schema.

The \`summary\` field should be a single sentence describing what you accomplished.

The \`freeform\` field is the most important part of your output — write it as
if briefing a colleague who's picking up tomorrow. Cover:

- What you did and why you made the choices you made
- Anything that surprised you or didn't go as expected
- Anything that's fragile, incomplete, or needs attention
- What you'd recommend the next iteration focus on
- Key technical details the next person needs to know

The structured fields (task_completed, files_touched, etc.) help the
orchestrator track progress. The freeform narrative is how the next
iteration will actually understand what happened."
    fi
    local output_section="## Output Instructions
${output_instructions}"

    # Assemble sections in canonical order
    prompt+="$task_section"$'\n\n'
    prompt+="$failure_section"$'\n\n'
    prompt+="$retrieved_memory_section"$'\n\n'
    prompt+="$previous_handoff_section"$'\n\n'
    if [[ -n "$retrieved_project_memory_section" ]]; then
        prompt+="$retrieved_project_memory_section"$'\n\n'
    fi
    if [[ -n "$accumulated_knowledge_section" ]]; then
        prompt+="$accumulated_knowledge_section"$'\n\n'
    fi
    prompt+="$skills_section"$'\n\n'
    prompt+="$output_section"

    echo "$prompt"
}

# build_coding_prompt — Legacy v1 prompt builder (fallback)
# Used when build_coding_prompt_v2 is not available (should not happen in normal operation).
# Kept for backward compatibility with older test fixtures.
# Args: $1-$6 = task_json, compacted_context, prev_handoff, skills, failure_context, earlier_l1
build_coding_prompt() {
    local task_json="$1"
    local compacted_context="${2:-}"
    local prev_handoff="${3:-}"
    local skills_content="${4:-}"
    local failure_context="${5:-}"
    local earlier_l1="${6:-}"

    local failure_section=""
    if [[ -n "$failure_context" ]]; then
        failure_section="
## Validation Failure Context (RETRY)
The previous attempt at this task FAILED validation. Fix these issues:
${failure_context}"
    fi

    local earlier_section=""
    if [[ -n "$earlier_l1" ]]; then
        earlier_section="
## Earlier Iterations
${earlier_l1}"
    fi

    cat <<PROMPT
## Current Task
$(echo "$task_json" | jq -r '"ID: \(.id)\nTitle: \(.title)\n\nDescription:\n\(.description)\n\nAcceptance Criteria:\n" + (.acceptance_criteria | map("- " + .) | join("\n"))')

## Output Requirements
You MUST produce a handoff document as your final output. Structure your response as valid JSON matching the handoff schema provided via --json-schema.
After implementing, run the acceptance criteria checks yourself before producing the handoff.
${failure_section}
## Skills & Conventions
${skills_content:-"No specific skills loaded."}

## Previous Iteration Summary
${prev_handoff:-"No previous iteration."}

## Project Context (Compacted)
${compacted_context:-"No compacted context available. This is an early iteration."}
${earlier_section}
PROMPT
}
