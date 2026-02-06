# Bash Conventions

## Script Header
Every script and library module must start with:
```bash
#!/usr/bin/env bash
set -euo pipefail
```

## Variables
- Constants and config: `UPPER_SNAKE_CASE`
- Local variables: `lower_snake_case`
- Always quote expansions: `"$var"` not `$var`
- Use `local` for function variables: `local result=""`
- Use `readonly` for constants: `readonly MAX_RETRIES=3`

## Conditionals
- Use `[[ ]]` not `[ ]`:
  ```bash
  if [[ -f "$file" ]]; then
  if [[ "$status" == "done" ]]; then
  if [[ "$count" -gt 0 ]]; then
  ```
- Use `&&` / `||` for simple checks: `[[ -f "$file" ]] || return 1`

## Command Substitution
- Use `$(command)` not backticks
- Capture exit codes explicitly when needed:
  ```bash
  local output
  output=$(some_command) || { log "ERROR" "command failed"; return 1; }
  ```

## Error Handling
- Functions return 0 on success, non-zero on failure
- Use guard clauses early: `[[ -n "$1" ]] || { log "ERROR" "missing arg"; return 1; }`
- Trap for cleanup when managing temp files:
  ```bash
  local tmpfile
  tmpfile=$(mktemp)
  trap "rm -f '$tmpfile'" RETURN
  ```

## Logging
Use the shared `log` function defined in ralph.sh:
```bash
log "INFO" "Starting iteration $iteration"
log "ERROR" "Validation failed for $task_id"
log "DEBUG" "Raw output: $output"
```

## Functions
- Declare with `name() {` syntax (no `function` keyword)
- Document parameters in a brief comment if not obvious
- Keep functions under 50 lines; extract helpers if longer
