# Pipeline Test Logbook

> Structured observations from Ralph Deluxe pipeline test runs. Each entry captures
> what happened, what the data shows, and what to fix before the next run.
>
> **Convention**: Append new runs chronologically. Never edit previous entries — they're
> the historical record. Add corrections as new entries referencing the old one.

---

## Run Index

| Run | Date | Branch | Tasks | Result | Key Finding |
|-----|------|--------|-------|--------|-------------|
| [RUN-001](#run-001) | 2026-02-12 | main@`77d53b6` | 14/14 | PASS (tasks) | 100% synthetic handoffs — root cause: `.structured_output` field never read |

---

## RUN-001

**Date**: 2026-02-12 12:51 UTC
**Branch**: `main` @ `77d53b6` (Fix context prep fallback)
**Workspace**: `/tmp/ralph-test-20260212-135016`
**Mode**: `agent-orchestrated`
**Max iterations**: 30
**Validation**: strict (Jest + ESLint + Playwright)

### Pre-Run Fixes Applied

Two bugs fixed before this run could start:

1. **Context prep fallback crash** (`agents.sh`): `${AGENT_PROMPT_REQUIRED_HEADERS[@]}` with `set -u`
   triggers "unbound variable" in bash 3.2 even when array IS defined. Combined with `set -e` leaking
   into subshells inside conditionals. Fix: inline header list, early return in fallback path.
2. **Playwright integration**: Added `@playwright/test` as 3rd validation command, seed browser tests,
   `webServer` config in `playwright.config.js`.

### Final Results — 14/14 tasks, 0 retries, 1h 37m

| Iter | Task | Retries | Duration | Turns | Jest | Playwright | Freeform |
|------|------|---------|----------|-------|------|------------|----------|
| 1 | TASK-001: Bootstrap Express server | 0 | 3m42s | 16 | 5 | 3 | 709ch |
| 2 | TASK-002: In-memory data model | 0 | 2m58s | 16 | 32 | 3 | 302ch |
| 3 | TASK-003: REST API endpoints | 0 | 3m50s | 20 | 44 | 3 | 882ch |
| 4 | TASK-004: Input validation middleware | 0 | 4m11s | 22 | 69 | 3 | 339ch |
| 5 | TASK-005: Filtering & pagination | 0 | 3m43s | 16 | 88 | 3 | 336ch |
| 6 | TASK-006: Frontend HTML structure | 0 | 4m43s | 23 | 105 | 8 | 855ch |
| 7 | TASK-007: Frontend JS + rendering | 0 | 6m51s | 36 | 117 | 15 | 323ch |
| 8 | TASK-008: Todo CRUD UI | 0 | 3m52s | 16 | 133 | 15 | 304ch |
| 9 | TASK-009: Error handling system | 0 | 10m32s | 59 | 146 | 20 | 991ch |
| 10 | TASK-010: Status filters | 0 | 6m43s | 35 | 165 | 20 | 435ch |
| 11 | TASK-011: Category system | 0 | 4m24s | 23 | 171 | 20 | 879ch |
| 12 | TASK-012: Priority system | 0 | 5m42s | 29 | 212 | 20 | 389ch |
| 13 | TASK-013: Due date system | 0 | 8m09s | 45 | 227 | 20 | 979ch |
| 14 | TASK-014: Search & keyboard shortcuts | 0 | 10m40s | ?? | 257 | 29 | 415ch |

**Totals**: 14 iterations, 0 retries, 100% validation pass rate, 5→257 Jest tests, 3→29 Playwright tests.
Average iteration: ~5m42s (backend ~3m41s, frontend ~6m36s).

### Communication Loop Analysis

#### Context Prep → Coding Agent (prepared-prompt.md)

The context agent produces a clean 7-section prompt. Sample from iteration 5 (7.5KB):

| Section | Content Quality | Notes |
|---------|----------------|-------|
| `## Current Task` | Excellent | Full task JSON + step-by-step implementation details |
| `## Failure Context` | N/A | No failures triggered (0 retries) |
| `## Retrieved Memory` | Good | 3 curated bullet points from previous iteration |
| `## Previous Handoff` | Degraded | Working from synthetic freeform — compressed but loses nuance |
| `## Retrieved Project Memory` | Good | 8 knowledge entries (K-decision, K-pattern) |
| `## Skills` | Empty | No skills matched this task |
| `## Output Instructions` | Good | Standard template from coding-prompt-footer.md |

**Prompt quality verdict**: The context agent compensates well for degraded handoffs. It extracts
key facts from synthetic freeform and cross-references with the knowledge index. The coding agent
gets actionable, self-contained prompts every time.

#### Coding Agent → Handoff (handoff-NNN.json)

**Critical finding: 100% synthetic handoffs.** The coding agent never produces structured JSON.

| Iter | Freeform Length | Synthetic | task_id | Signals | Agent Summary Captured |
|------|----------------|-----------|---------|---------|----------------------|
| 1 | 709 chars | yes | unknown | none | yes — truncated |
| 2 | 302 chars | yes | unknown | none | yes — brief |
| 3 | 882 chars | yes | unknown | none | yes — good detail |
| 4 | 339 chars | yes | unknown | none | yes — brief |
| 5 | 336 chars | yes | unknown | none | no — git metadata only |
| 6 | 855 chars | yes | unknown | none | yes — good detail |

**What's lost in synthetic handoffs:**

| Field | Expected | Actual | Impact |
|-------|----------|--------|--------|
| `freeform` | 200+ char narrative | Mixed (302-882ch) | Iteration 5 had only git metadata — context agent had to reconstruct |
| `task_completed.task_id` | "TASK-00N" | "unknown" | Orchestrator infers from validation, not handoff |
| `confidence_level` | high/medium/low | absent | Feedback loop to context agent broken |
| `request_research` | topic list | [] | No research requests ever flow back |
| `request_human_review` | {needed, reason} | absent | Human review signal never fires |
| `deviations` | list of plan deviations | [] | No structured deviation tracking |
| `constraints_discovered` | list | [] | Knowledge index gets constraints only via freeform extraction |
| `architectural_notes` | list | [] | Context post agent must infer architecture from code |
| `tests_added` | list of test files | [] | Context agent can't track test coverage growth |

**Root cause (discovered post-run)**: `claude -p --json-schema` DOES enforce JSON via constrained
decoding (`output_config.format`). The schema-validated output goes into **`.structured_output`**
in the CLI response envelope — NOT `.result`. Ralph's `parse_handoff_output()` reads `.result`
(which is empty when structured output succeeds) and falls through to synthetic. The actual
structured JSON with all signal fields was present in every response — we just never read it.

Verified empirically: `echo "..." | claude -p --json-schema '...' --max-turns 5` produces
`{"result":"","structured_output":{...valid JSON...}}` — even with tool use.

#### Context Post → Knowledge Index

Despite degraded handoffs, the knowledge index accumulated strongly:

- **66 entries** after 14 iterations (33 decisions, 32 patterns, 1 gotcha, 0 constraints, 0 unresolved)
- Correctly cross-references source iterations
- Detected its own limitation: `K-gotcha-synthetic-handoff`
- No verification failures (no rollbacks needed)

### Validation Gate

All 14 iterations passed strict validation (all 3 commands) on first attempt:

| Command | Pass Rate | Notes |
|---------|-----------|-------|
| `npx jest` | 14/14 | 5 → 257 tests across 16 suites |
| `npx eslint --max-warnings 0` | 14/14 | Zero warnings throughout |
| `npx playwright test` | 14/14 | 3 → 29 tests, frontend integration covered |

### Key Findings

1. **The agent-orchestrated mode works end-to-end.** 14/14 tasks completed in 14 iterations,
   zero retries, 100% validation pass rate. The three-agent loop (context prep → coding →
   context post) produces working, tested code every iteration.

2. **The structured output was there all along.** The coding agent DID produce schema-compliant
   JSON via constrained decoding — it was in `.structured_output`, not `.result`. Ralph's
   `parse_handoff_output()` never checked that field. This single bug explains 100% of
   synthetic handoffs. Fix: check `.structured_output` first in all parse functions.

3. **Context agent compensates remarkably well.** Even with 100% synthetic handoffs, the
   knowledge index grew to 66 entries and the prepared prompts included actionable details.
   The system is far more resilient than expected — a testament to the architecture.

4. **Test count growth is monotonic.** Jest: 5 → 257, Playwright: 3 → 29. No test regressions
   across 14 iterations. The strict validation strategy (all 3 commands must pass) works.

5. **Iteration timing scales with complexity.** Backend tasks: ~3m41s avg. Frontend tasks:
   ~6m36s avg. Complex tasks (TASK-009: error handling, TASK-014: search) take 10+ minutes.
   Context prep overhead is ~1min fixed cost per iteration.

6. **Prompt sizes stay bounded.** Range: 5.2KB–17.3KB (1.3K–4.3K tokens). The knowledge
   index growth doesn't cause unbounded prompt expansion — context agent curates well.

### Hypotheses Tested

| # | Hypothesis | Result | Conclusion |
|---|-----------|--------|------------|
| H1 | Stronger JSON reminder → more structured handoffs | **Irrelevant** | Root cause was `.structured_output` vs `.result` field mismatch, not prompt quality |
| H2 | Reducing max_turns → earlier JSON | **Irrelevant** | Agents used 16-59 turns (well under 200), JSON was being produced |
| H3 | Extraction agent pass → guaranteed structured output | **Still valuable** as safety net | Useful for edge cases (max_tokens, refusals) even after `.structured_output` fix |
| H4 | Playwright on frontend → first retries | **Rejected** | 0 retries across all 14 tasks including 8 frontend tasks |
| H5 | Knowledge index growth slows | **Partially confirmed** | 66 entries after 14 iters (4.7/iter) — steady but not accelerating |

### Action Items for Next Run (RUN-002)

- [x] **Fix `.structured_output` field reading** — Root cause of 100% synthetic handoffs. Fixed
      in `parse_handoff_output()`, `parse_agent_output()`, and `run_handoff_extraction()`.
- [ ] **Run RUN-002 to validate fix** — Target: >80% structured handoffs (was 0%). All signal
      fields (confidence_level, request_research, request_human_review) should now flow.
- [ ] **Fix analyze.sh prompt size table** — Headers repeated per iteration instead of once.
- [ ] **Fix analyze.sh test count table** — Same repeated-header bug, also unsorted.

---

<!-- TEMPLATE FOR NEW RUNS — copy below this line -->
<!--
## RUN-NNN

**Date**: YYYY-MM-DD HH:MM UTC
**Branch**: `branch` @ `commit`
**Workspace**: `/tmp/ralph-test-YYYYMMDD-HHMMSS`
**Mode**: `agent-orchestrated`
**Previous Run**: RUN-NNN (link to comparison)
**Changes Since Last Run**: What was fixed/changed

### Task Progress

| Iter | Task | Status | Retries | Duration | Validation |
|------|------|--------|---------|----------|------------|

### Communication Loop Analysis

#### Context Prep → Coding Agent
#### Coding Agent → Handoff
#### Context Post → Knowledge Index

### Validation Gate

### Key Findings

### Hypotheses Tested (from previous run)

| # | Hypothesis | Result | Conclusion |
|---|-----------|--------|------------|

### New Hypotheses

### Action Items for Next Run
-->
