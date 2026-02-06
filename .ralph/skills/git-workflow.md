# Git Workflow for Ralph Deluxe

## Checkpoint Before Iteration
Capture the current HEAD so you can roll back if the iteration fails:
```bash
local checkpoint
checkpoint=$(git rev-parse HEAD)
```

## Rollback on Failure
Reset to the checkpoint and clean up any new untracked files. The `--exclude` preserves Ralph's runtime state:
```bash
git reset --hard "$checkpoint"
git clean -fd --exclude=.ralph/
```

## Commit on Success
Stage everything and commit with the Ralph commit format:
```bash
git add -A
git commit -m "ralph[$iteration]: $task_id -- $message"
```

## Ensure Clean State Before Starting
Always check for uncommitted changes before beginning an iteration:
```bash
if [[ -n "$(git status --porcelain)" ]]; then
    log "ERROR" "Working directory is not clean"
    return 1
fi
```

## Commit Message Format
```
ralph[N]: TASK-ID -- short description
```
- `N` is the iteration number
- `TASK-ID` matches the task ID from plan.json
- Description summarizes what was accomplished

## Rules
- Never force push
- Every successful iteration gets exactly one commit
- Failed iterations leave no trace in git history
- The `.ralph/` directory state files are excluded from rollback cleanup
