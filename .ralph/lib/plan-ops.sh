#!/usr/bin/env bash
# plan-ops.sh — Plan reading and mutation functions for Ralph Deluxe

# Return the first pending task whose dependencies are all satisfied (status "done").
# Outputs the full task JSON object, or empty string if none found.
get_next_task() {
    local plan_file="${1:-plan.json}"
    jq -c '
        .tasks as $all |
        [.tasks[] | select(.status == "pending")] |
        map(select(
            .depends_on as $deps |
            ($deps | length == 0) or
            ([$deps[] | . as $d | $all[] | select(.id == $d and .status == "done")] | length) == ($deps | length)
        )) |
        first // empty
    ' "$plan_file"
}

# Update a task's status in plan.json. Uses safe temp-file pattern.
set_task_status() {
    local plan_file="$1"
    local task_id="$2"
    local new_status="$3"
    local tmp
    tmp="$(mktemp)"
    jq --arg id "$task_id" --arg status "$new_status" \
        '.tasks = [.tasks[] | if .id == $id then .status = $status else . end]' \
        "$plan_file" > "$tmp" && mv "$tmp" "$plan_file"
    log "info" "Set task $task_id status to $new_status"
}

# Retrieve a task's full JSON by ID.
get_task_by_id() {
    local plan_file="$1"
    local task_id="$2"
    jq -c --arg id "$task_id" '.tasks[] | select(.id == $id)' "$plan_file"
}

# Process plan_amendments array from a handoff JSON file.
# Applies add/modify/remove operations with safety guardrails.
apply_amendments() {
    local plan_file="$1"
    local handoff_file="$2"
    local current_task_id="${3:-}"

    local amendments_log="${RALPH_DIR:-$(dirname "$plan_file")/.ralph}/logs/amendments.log"

    # Extract amendments array
    local amendments
    amendments="$(jq -c '.plan_amendments // []' "$handoff_file")"

    local count
    count="$(echo "$amendments" | jq 'length')"

    if [[ "$count" -eq 0 ]]; then
        log "debug" "No plan amendments to apply"
        return 0
    fi

    # Safety: max 3 amendments per iteration
    if [[ "$count" -gt 3 ]]; then
        log "warn" "Rejecting amendments: $count exceeds maximum of 3"
        echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] REJECTED: $count amendments exceed max of 3" >> "$amendments_log"
        return 1
    fi

    # Backup plan before mutation
    cp "$plan_file" "${plan_file}.bak"
    log "info" "Backed up plan to ${plan_file}.bak"

    local i=0
    while [[ "$i" -lt "$count" ]]; do
        local amendment
        amendment="$(echo "$amendments" | jq -c ".[$i]")"
        local action
        action="$(echo "$amendment" | jq -r '.action')"
        local amendment_task_id
        amendment_task_id="$(echo "$amendment" | jq -r '.task_id // empty')"
        local reason
        reason="$(echo "$amendment" | jq -r '.reason // "no reason given"')"

        case "$action" in
            add)
                local new_task
                new_task="$(echo "$amendment" | jq -c '.task // empty')"

                # Validate required fields
                local has_id has_title has_desc
                has_id="$(echo "$new_task" | jq -r '.id // empty')"
                has_title="$(echo "$new_task" | jq -r '.title // empty')"
                has_desc="$(echo "$new_task" | jq -r '.description // empty')"

                if [[ -z "$has_id" || -z "$has_title" || -z "$has_desc" ]]; then
                    log "warn" "Rejecting add amendment: missing id, title, or description"
                    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] REJECTED add: missing required fields — $reason" >> "$amendments_log"
                    i=$((i + 1))
                    continue
                fi

                # Add default fields if missing
                new_task="$(echo "$new_task" | jq -c '. + {
                    status: (.status // "pending"),
                    order: (.order // 999),
                    skills: (.skills // []),
                    needs_docs: (.needs_docs // false),
                    libraries: (.libraries // []),
                    acceptance_criteria: (.acceptance_criteria // []),
                    depends_on: (.depends_on // []),
                    max_turns: (.max_turns // 20),
                    retry_count: (.retry_count // 0),
                    max_retries: (.max_retries // 2)
                }')"

                local after
                after="$(echo "$amendment" | jq -r '.after // empty')"

                local tmp
                tmp="$(mktemp)"
                if [[ -n "$after" ]]; then
                    # Insert after the specified task
                    jq --arg after_id "$after" --argjson task "$new_task" '
                        (.tasks | to_entries | map(select(.value.id == $after_id)) | first.key // -1) as $idx |
                        if $idx >= 0 then
                            .tasks = .tasks[:$idx+1] + [$task] + .tasks[$idx+1:]
                        else
                            .tasks += [$task]
                        end
                    ' "$plan_file" > "$tmp" && mv "$tmp" "$plan_file"
                else
                    # Append to end
                    jq --argjson task "$new_task" '.tasks += [$task]' "$plan_file" > "$tmp" && mv "$tmp" "$plan_file"
                fi

                log "info" "Amendment: added task $has_id"
                echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ADD $has_id — $reason" >> "$amendments_log"
                ;;

            modify)
                if [[ -z "$amendment_task_id" ]]; then
                    log "warn" "Rejecting modify amendment: no task_id"
                    i=$((i + 1))
                    continue
                fi

                # Cannot modify the currently executing task's status
                local changes
                changes="$(echo "$amendment" | jq -c '.changes // {}')"
                local changes_status
                changes_status="$(echo "$changes" | jq -r '.status // empty')"

                if [[ -n "$current_task_id" && "$amendment_task_id" == "$current_task_id" && -n "$changes_status" ]]; then
                    log "warn" "Rejecting modify: cannot change status of current task $current_task_id"
                    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] REJECTED modify $amendment_task_id: cannot change current task status — $reason" >> "$amendments_log"
                    i=$((i + 1))
                    continue
                fi

                local tmp
                tmp="$(mktemp)"
                jq --arg id "$amendment_task_id" --argjson changes "$changes" \
                    '.tasks = [.tasks[] | if .id == $id then . + $changes else . end]' \
                    "$plan_file" > "$tmp" && mv "$tmp" "$plan_file"

                log "info" "Amendment: modified task $amendment_task_id"
                echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] MODIFY $amendment_task_id — $reason" >> "$amendments_log"
                ;;

            remove)
                if [[ -z "$amendment_task_id" ]]; then
                    log "warn" "Rejecting remove amendment: no task_id"
                    i=$((i + 1))
                    continue
                fi

                # Cannot remove tasks with status "done"
                local task_status
                task_status="$(jq -r --arg id "$amendment_task_id" '.tasks[] | select(.id == $id) | .status' "$plan_file")"

                if [[ "$task_status" == "done" ]]; then
                    log "warn" "Rejecting remove: task $amendment_task_id has status 'done'"
                    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] REJECTED remove $amendment_task_id: status is done — $reason" >> "$amendments_log"
                    i=$((i + 1))
                    continue
                fi

                local tmp
                tmp="$(mktemp)"
                jq --arg id "$amendment_task_id" \
                    '.tasks |= map(select(.id != $id))' \
                    "$plan_file" > "$tmp" && mv "$tmp" "$plan_file"

                log "info" "Amendment: removed task $amendment_task_id"
                echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] REMOVE $amendment_task_id — $reason" >> "$amendments_log"
                ;;

            *)
                log "warn" "Unknown amendment action: $action"
                echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] REJECTED unknown action: $action — $reason" >> "$amendments_log"
                ;;
        esac

        i=$((i + 1))
    done

    return 0
}

# Return 0 if all tasks have status "done" or "skipped", 1 otherwise.
is_plan_complete() {
    local plan_file="${1:-plan.json}"
    local remaining
    remaining="$(jq '[.tasks[] | select(.status != "done" and .status != "skipped")] | length' "$plan_file")"
    if [[ "$remaining" -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Return count of pending + failed tasks.
count_remaining_tasks() {
    local plan_file="${1:-plan.json}"
    jq '[.tasks[] | select(.status == "pending" or .status == "failed")] | length' "$plan_file"
}
