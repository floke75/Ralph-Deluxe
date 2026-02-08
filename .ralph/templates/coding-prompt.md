<!-- Reference template: documents the prompt structure built by build_coding_prompt_v2() in context.sh.
     This file is NOT read at runtime — the prompt is assembled programmatically.
     Section headers must match exactly (context.sh truncation parses ^## headers).
     Section order must match build_coding_prompt_v2() assembly order. -->

## Current Task
{{TASK_SECTION}}
<!-- Always present. Contains: ID, Title, Description, Acceptance Criteria from plan.json task. -->

## Failure Context
{{FAILURE_CONTEXT}}
<!-- Only present on retry iterations. Contains previous validation output.
     Default: "No failure context." -->

## Retrieved Memory
{{RETRIEVED_MEMORY}}
<!-- Always present. Content varies by mode:
     - Both modes: constraints + decisions extracted from latest handoff JSON
       (constraints_discovered[].constraint + workaround/impact, architectural_notes[])
     - handoff-plus-index mode: also includes "### Knowledge Index" pointer to .ralph/knowledge-index.md
     Default (no handoffs): "No retrieved memory available." -->

## Previous Handoff
{{PREV_HANDOFF}}
<!-- Iteration 2+ only. Content varies by mode:
     - handoff-only mode: freeform narrative only (from get_prev_handoff_for_mode)
     - handoff-plus-index mode: freeform narrative + structured L2 block
       (deviations, failed bugs, constraints, unfinished business)
     First iteration: "This is the first iteration. No previous handoff available." -->

## Retrieved Project Memory
{{RETRIEVED_PROJECT_MEMORY}}
<!-- handoff-plus-index mode only. Present only when matches found.
     Contains: top-k (max 12) keyword-matched entries from .ralph/knowledge-index.md
     via retrieve_relevant_knowledge(). Category priority:
     Constraints > Architectural Decisions > Unresolved > Gotchas > Patterns -->

## Accumulated Knowledge
{{ACCUMULATED_KNOWLEDGE}}
<!-- handoff-plus-index mode only. Present only when .ralph/knowledge-index.md exists.
     Static pointer: "A knowledge index of learnings from all previous iterations is
     available at .ralph/knowledge-index.md. Consult it if you need project history
     beyond what's in the handoff above."
     Lowest truncation priority — removed first under budget pressure. -->

## Skills
{{SKILLS_SECTION}}
<!-- Present when task has skills[] array entries. Loads from .ralph/skills/<name>.md.
     Default: "No specific skills loaded." -->

## Output Instructions
<!-- Always present. Loaded from .ralph/templates/coding-prompt-footer.md if it exists,
     otherwise uses inline fallback in build_coding_prompt_v2(). -->

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
