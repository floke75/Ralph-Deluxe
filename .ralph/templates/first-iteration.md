# First Iteration

This is **iteration 1** of the Ralph Deluxe orchestrator run. There is no previous context, no compacted history, and no prior handoff documents.

## What This Means
- You are starting from a clean slate
- No architectural decisions have been recorded yet
- No constraints have been discovered yet
- The conventions you establish now will carry forward through all future iterations

## Your Focus
1. Read the task description and acceptance criteria carefully
2. Implement exactly what is specified — no more, no less
3. Follow the project conventions defined in CLAUDE.md
4. Run the acceptance criteria checks before finalizing your output

## Handoff Document Importance
Your handoff document is critical because it seeds all future context. Future iterations will build on what you record here. Be thorough:
- Document every architectural decision you make and why
- Record any constraints you discover about the environment or tools
- List every file you create, modify, or delete
- Note any deviations from the plan with clear reasoning
- If you encounter bugs, document the problem AND the resolution

The handoff JSON must match the schema provided via --json-schema. This is not optional — the orchestrator parses your handoff to build context for the next iteration.
