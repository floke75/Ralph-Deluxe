<!-- Reference template: documents the prompt structure built by build_coding_prompt_v2() in context.sh.
     This file is NOT read at runtime — the prompt is assembled programmatically. -->

## Current Task
{{TASK_SECTION}}

## Previous Attempt Failed
{{FAILURE_CONTEXT}}
<!-- Only present on retries -->

## Handoff from Previous Iteration
{{PREV_HANDOFF}}
<!-- handoff-only mode: freeform narrative only.
     handoff-plus-index mode: freeform + structured context from previous iteration.
     First iteration: "This is the first iteration. No previous handoff available." -->

## Accumulated Knowledge
<!-- handoff-plus-index mode only. Points to .ralph/knowledge-index.md for project history. -->

## Skills & Conventions
{{SKILLS_SECTION}}

## When You're Done

After completing your implementation and verifying the acceptance criteria,
write a handoff for whoever picks up this project next.

Your output must be valid JSON matching the provided schema.

The `summary` field should be a single sentence describing what you accomplished.

The `freeform` field is the most important part of your output — write it as
if briefing a colleague who's picking up tomorrow. Cover:

- What you did and why you made the choices you made
- Anything that surprised you or didn't go as expected
- Anything that's fragile, incomplete, or needs attention
- What you'd recommend the next iteration focus on
- Key technical details the next person needs to know

The structured fields (task_completed, files_touched, etc.) help the
orchestrator track progress. The freeform narrative is how the next
iteration will actually understand what happened.
