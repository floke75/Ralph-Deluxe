#!/usr/bin/env bash
set -euo pipefail

# context.sh — Context assembly functions for Ralph Deluxe
# Primary function: build_coding_prompt_v2() — handoff-first prompt assembly.
# Also contains legacy build_coding_prompt() for backward compatibility.

# Source config if not already loaded
if [[ -z "${RALPH_CONTEXT_BUDGET_TOKENS:-}" ]]; then
    RALPH_CONTEXT_BUDGET_TOKENS=8000
fi

# log() stub for standalone testing — ralph.sh provides the real one
if ! declare -f log >/dev/null 2>&1; then
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2" >&2; }
fi

# estimate_tokens — Approximate token count: chars / 4
estimate_tokens() {
    local text="$1"
    echo $(( ${#text} / 4 ))
}

# truncate_to_budget — If content exceeds budget, truncate from end preserving priority-ordered beginning
truncate_to_budget() {
    local content="$1"
    local budget_tokens="${2:-${RALPH_CONTEXT_BUDGET_TOKENS}}"
    local max_chars=$(( budget_tokens * 4 ))

    local current_chars=${#content}
    if [[ "$current_chars" -le "$max_chars" ]]; then
        echo "$content"
        return
    fi

    echo "${content:0:$max_chars}"
    echo ""
    echo "[CONTEXT TRUNCATED — ${current_chars} chars exceeded ${max_chars} char budget]"
}

# load_skills — Read and concatenate skill files based on task's skills array
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

# get_prev_handoff_summary — Extract L2 summary from most recent handoff JSON
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

# get_prev_handoff_for_mode — Return context from the latest handoff based on mode
# In handoff-only mode, returns the freeform narrative (the primary memory artifact).
# In handoff-plus-index mode, returns freeform + structured L2 for richer context.
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
            # Return freeform + structured L2 for richer context
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
    esac
}

# get_earlier_l1_summaries — Get L1 summaries from the 2nd and 3rd most recent handoffs
# These provide lightweight context about recent work beyond the immediate previous iteration.
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

# format_compacted_context — Transform compacted context JSON into markdown sections
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

# retrieve_relevant_knowledge — Pull a bounded set of relevant lines from the knowledge index
# Relevance is based on task id, title/description keywords, and listed libraries.
# Category priority: Constraints > Architectural Decisions > Unresolved > Gotchas > Patterns
retrieve_relevant_knowledge() {
    local task_json="$1"
    local index_file="${2:-.ralph/knowledge-index.md}"
    local max_lines="${3:-12}"

    if [[ ! -f "$index_file" ]]; then
        echo ""
        return
    fi

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

# build_coding_prompt_v2 — Mode-aware prompt assembly using handoff-first context
# In handoff-only mode: previous handoff narrative IS the context (no compacted context)
# In handoff-plus-index mode: handoff leads, plus a pointer to the knowledge index file
build_coding_prompt_v2() {
    local task_json="$1"
    local mode="${2:-handoff-only}"
    local skills_content="$3"
    local failure_context="$4"

    local handoffs_dir=".ralph/handoffs"
    local prompt=""

    # === TASK (always) ===
    prompt+="## Current Task"$'\n'
    prompt+="$(echo "$task_json" | jq -r '"ID: \(.id)\nTitle: \(.title)\n\nDescription:\n\(.description)\n\nAcceptance Criteria:\n" + (.acceptance_criteria | map("- " + .) | join("\n"))')"$'\n\n'

    # === FAILURE CONTEXT (if retrying) ===
    if [[ -n "$failure_context" ]]; then
        prompt+="## Previous Attempt Failed"$'\n'
        prompt+="$failure_context"$'\n\n'
    fi

    # === PREVIOUS HANDOFF (always — this is the core) ===
    local prev_handoff
    prev_handoff="$(get_prev_handoff_for_mode "$handoffs_dir" "$mode")"
    if [[ -n "$prev_handoff" ]]; then
        prompt+="## Handoff from Previous Iteration"$'\n'
        prompt+="$prev_handoff"$'\n\n'
    else
        prompt+="## Context"$'\n'
        prompt+="This is the first iteration. No previous handoff available."$'\n\n'
    fi

    # === RETRIEVED PROJECT MEMORY (handoff-plus-index mode only) ===
    if [[ "$mode" == "handoff-plus-index" && -f ".ralph/knowledge-index.md" ]]; then
        local retrieved_memory
        retrieved_memory="$(retrieve_relevant_knowledge "$task_json" ".ralph/knowledge-index.md" 12)"
        if [[ -n "$retrieved_memory" ]]; then
            prompt+="## Retrieved Project Memory"$'\n'
            prompt+="$retrieved_memory"$'\n\n'
        fi
    fi

    # === KNOWLEDGE INDEX POINTER (handoff-plus-index mode only) ===
    if [[ "$mode" == "handoff-plus-index" && -f ".ralph/knowledge-index.md" ]]; then
        prompt+="## Accumulated Knowledge"$'\n'
        prompt+="A knowledge index of learnings from all previous iterations "
        prompt+="is available at .ralph/knowledge-index.md. Consult it if you "
        prompt+="need project history beyond what's in the handoff above."$'\n\n'
    fi

    # === SKILLS (if any) ===
    if [[ -n "$skills_content" ]]; then
        prompt+="## Skills & Conventions"$'\n'
        prompt+="$skills_content"$'\n\n'
    fi

    # === OUTPUT INSTRUCTIONS ===
    local output_instructions
    output_instructions="$(cat .ralph/templates/coding-prompt-footer.md 2>/dev/null)" || true
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
    prompt+="$output_instructions"

    echo "$prompt"
}

# build_coding_prompt — Assemble prompt from task JSON + context sections
# Priority order (highest first): task > output instructions > failure context > skills > previous L2 > compacted context > earlier L1
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
