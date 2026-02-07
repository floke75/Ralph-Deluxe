# jq Patterns for Ralph Deluxe

## Reading Tasks by Status
```bash
jq '.tasks[] | select(.status == "pending")' plan.json
```

## Get First Pending Task
```bash
jq '[.tasks[] | select(.status == "pending")] | first' plan.json
```

## Setting Task Status
```bash
jq --arg id "$task_id" --arg new "done" \
  '(.tasks[] | select(.id == $id)).status = $new' plan.json
```

## Counting Tasks by Status
```bash
jq '[.tasks[] | select(.status == "pending")] | length' plan.json
```

## Array Insertion (after index)
```bash
jq --argjson idx "$index" --argjson task "$task_json" \
  '.tasks = .tasks[:$idx+1] + [$task] + .tasks[$idx+1:]' plan.json
```

## Delete Task by ID
```bash
jq --arg id "$task_id" \
  '.tasks |= map(select(.id != $id))' plan.json
```

## Modify Task by ID
```bash
jq --arg id "$task_id" --arg key "status" --arg val "done" \
  '(.tasks[] | select(.id == $id))[$key] = $val' plan.json
```

## Extract One-Line Summary from Handoff
```bash
jq -r '"[\(.task_completed.task_id)] \(.task_completed.summary | split(". ")[0]). \(if .task_completed.fully_complete then "Complete" else "Partial" end). \(.files_touched | length) files."' handoff.json
```

## Extract Structured Details from Handoff
```bash
jq -r '{
  task: .task_completed.task_id,
  decisions: .architectural_notes,
  deviations: [.deviations[] | "\(.planned) -> \(.actual): \(.reason)"],
  constraints: [.constraints_discovered[] | "\(.constraint): \(.workaround // .impact)"],
  failed: [.bugs_encountered[] | select(.resolved == false) | .description],
  unfinished: [(.unfinished_business // [])[] | "\(.item) (\(.priority))"]
}' handoff.json
```

## Update state.json Counters
```bash
jq --arg iter "$iteration" \
  '.current_iteration = ($iter | tonumber) |
   .coding_iterations_since_compaction += 1' state.json
```

## Safe In-Place Update Pattern
```bash
local tmp
tmp=$(mktemp)
jq '...' "$file" > "$tmp" && mv "$tmp" "$file"
```
