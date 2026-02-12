## Output Instructions

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

### Signal Fields

Fill these accurately — they directly control what happens next:

- `confidence_level`: Set to "high", "medium", or "low". If you're unsure
  about your implementation, say so — this triggers extra validation.
- `request_research`: List any topics you need researched before the next
  iteration (library APIs, patterns, etc.). The context agent will investigate.
- `request_human_review`: Set `needed: true` with a reason if you hit
  something that requires human judgment.

---

**CRITICAL — YOUR FINAL OUTPUT MUST BE JSON**

When you are done with all coding, testing, and validation, your very last
message must be a single JSON object. Not conversational text. Not a summary
followed by JSON. Just the JSON object matching the schema.

Do NOT write "Here's my handoff:" or "All done!" before the JSON.
Do NOT wrap the JSON in markdown code fences.
Your entire final response must be parseable by `JSON.parse()`.

Example of the EXACT format expected:

```
{"summary":"Implemented error handling system with custom error classes and global middleware","freeform":"Built ValidationError and NotFoundError classes extending Error...","task_completed":{"task_id":"TASK-009","summary":"Error handling system complete","fully_complete":true},"confidence_level":"high","request_research":[],"request_human_review":{"needed":false,"reason":""},"deviations":[],"bugs_encountered":[],"architectural_notes":["Error handler uses 4-arg Express middleware pattern"],"files_touched":[{"path":"src/middleware/errorHandler.js","action":"created"}],"plan_amendments":[],"tests_added":[{"file":"tests/middleware/errorHandler.test.js","test_names":["returns 404 for NotFoundError"]}],"constraints_discovered":[],"unfinished_business":[],"recommendations":["Consider adding request ID tracking"]}
```

The orchestrator parses your output as JSON. If you output text instead of
JSON, your insights are LOST — the system falls back to a synthetic handoff
built only from git metadata, and all your signal fields (confidence_level,
request_research, request_human_review) are discarded.
