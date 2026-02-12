# 40-Pattern Evaluation: What Ralph Needs vs. Already Has

## Context

Ralph Deluxe completed its first end-to-end pipeline test (RUN-001: 14-task Node.js project, agent-orchestrated mode). Results: 10/14 tasks done with 0 retries, all validations passing — but **100% synthetic handoffs** (the coding agent never produces structured JSON). The feedback loop (`request_research`, `confidence_level`, `request_human_review`) is completely dead.

This evaluation maps the 50 patterns from `40-Ralph-Patterns.md` against (a) what Ralph already implements, (b) what RUN-001 actually exposed as problems, and (c) ideal implementation order.

## Triage: Skip / Upgrade / Add / Defer

### SKIP — Already implemented or redundant (19 patterns)

| ID | Pattern | Why Skip |
|----|---------|----------|
| RD-004 | Verification callback with feedback injection | **Already done.** `validation.sh` writes failure context → `context.sh` injects as §2 Failure Context in next prompt. Truncated to 500 chars/check. |
| RD-005 | Pre-implementation health gate | **Mostly done.** `ensure_clean_state()` at startup + `create_checkpoint()` before each iteration. Gap: no merge-conflict scan — but Ralph always works on clean branches. |
| RD-009 | Backpressure-over-prescription | **Already the design philosophy.** Validation commands in `ralph.conf` define what must pass; coding agent figures out how. |
| RD-010 | Fix-plan checklist with auto-exit | **Already done differently.** `plan.json` task statuses + `is_plan_complete()` = same result. |
| RD-011 | Mechanical rules in gates, judgment in prompts | **Already the architecture.** Validation gate = mechanical. Prompt = judgment. |
| RD-013 | Key decisions table with rationale | **Already done.** Knowledge index `## Decisions` category with `[source: iter N]` provenance. |
| RD-024 | Session persistence with crash recovery | **Partially done.** `state.json` written every iteration. Resume flag parsed. Gap: lock file and crash-safe recovery — low priority since Ralph runs single-instance. |
| RD-025 | Schema-validated handoff documents | **Done.** `handoff-schema.json` with 12 required fields + fallback synthetic. Problem is enforcement, not schema. |
| RD-026 | Task-scoped context isolation | **Done.** Context prep agent builds per-task manifest. Each task gets fresh prompt from components. |
| RD-027 | Context budget management | **Done.** 7-priority truncation, two budgets (8K/16K tokens). |
| RD-028 | Codebase patterns in CLAUDE.md | **Done.** Knowledge index + first-iteration.md + skills = same function. |
| RD-029 | Dynamic prompt enrichment | **Done.** Context prep agent reads git state, recent handoffs, knowledge index, research requests. |
| RD-030 | Post-session knowledge harvesting | **Done.** Context post agent runs after every iteration, extracts patterns/decisions/gotchas into knowledge index. |
| RD-031 | Separate plan vs. build prompt modes | **Already separate.** `plan.json` = plan. Coding prompt = build. Ralph doesn't plan during build. |
| RD-038 | Discard-and-retry on validation failure | **Already done.** `rollback_to_checkpoint()` + retry with failure context injection. |
| RD-042 | Dependency-aware task auto-selection | **Done.** `get_next_task()` checks all `depends_on` are "done". |
| RD-043 | ID-linked commit traceability | **Done.** Commit format: `ralph[N]: TASK-ID — description`. |
| RD-044 | Iteration lifecycle hooks | **Mostly done.** Telemetry events at every boundary. Dashboard control commands. Gap: no user-script hooks — but telemetry + control covers the use case. |
| RD-047 | Electronic lab notebook | **Done.** `test-harness/LOGBOOK.md` + `events.jsonl` + `progress-log.md`. |

### UPGRADE — Partially implemented, worth completing (8 patterns)

| ID | Pattern | Current State | Gap to Fill | Effort |
|----|---------|---------------|-------------|--------|
| RD-006 | Separate verifier agent | Skeleton in `agents.json` + `review-agent-prompt.md`, disabled | Activate on `on_success` trigger, wire into main loop, test | Small |
| RD-007 | Human hint injection to prompt | `inject-note` command logs to telemetry stream | Route notes into next iteration's prompt (not just logs) | Minimal |
| RD-008 | Retry with exponential backoff | Fixed `RALPH_MIN_DELAY_SECONDS` (30s) | Scale delay by retry count: `delay * 2^retry_count` | Minimal |
| RD-015 | Cost/duration budget enforcement | Cost logged per-iteration via `extract_response_metadata()` | Accumulate in state.json, compare against `RALPH_MAX_COST_USD` / `RALPH_MAX_RUNTIME_SECS` | Small |
| RD-016 | Stale task auto-recovery | Only `depends_on` filtering in `get_next_task()` | Add timestamp check: if `in_progress` > N seconds, reset to pending | Minimal |
| RD-034 | Max-turns budget per task | System-level `RALPH_DEFAULT_MAX_TURNS` (200) | Allow `max_turns` in plan.json task schema, pass to CLI | Minimal |
| RD-035 | Max runtime safety cap | None | `START_TIME` at loop start, check before each iteration | Minimal |
| RD-036 | Append-system-prompt for constraints | Skills injected via `--append-system-prompt-file` | Add immutable behavioral rules (never modify outside scope, always run tests, etc.) | Minimal |

### ADD — New patterns with high value (9 patterns)

| ID | Pattern | Why Valuable | Effort |
|----|---------|-------------|--------|
| RD-001 | Failed-approaches log | **High.** Currently no structured "what was tried and failed" — only scattered across failure context and handoff `bugs_encountered[]`. On retries, agent may repeat same approach. | Minimal |
| RD-003 | Three-state circuit breaker | **High.** Stuck detection emits events but doesn't enforce anything. Runaway loops possible. | Small |
| RD-012 | Cross-model review loop | **Medium.** Uses cheaper model (Haiku) as reviewer. Skeleton exists — this extends it with a lighter model and SHIP/REVISE protocol. | Small |
| RD-014 | Guardrails-as-signs | **Medium.** Recurring mistakes (like the synthetic handoff issue) should auto-generate guardrail entries for future iterations. Knowledge index `gotcha` category is close but not injected early enough. | Small |
| RD-022 | Blocked signal detection | **Medium.** Agent can be stuck on unresolvable issues. `.ralph/BLOCKED.md` = simple escape hatch. | Minimal |
| RD-032 | Task size validation at plan time | **Low-medium.** No check today. Large tasks could exceed context. | Minimal |
| RD-033 | Scoped tool permissions per task | **Medium.** Currently `--dangerously-skip-permissions`. Per-task `allowedTools` would prevent scope creep. | Small |
| RD-045 | Multi-channel completion notifications | **Low.** Nice for long runs. `osascript` for macOS, webhook for Slack. | Minimal |
| RD-046 | LLM-as-judge for subjective quality | **Low-medium.** For tasks where acceptance criteria can't be tested mechanically. | Small |

### DEFER — Low priority or over-engineering for current scale (14 patterns)

| ID | Why Defer |
|----|-----------|
| RD-002 | Dual-condition exit gate — Ralph uses plan.json completion (not text parsing). False exits aren't a problem. |
| RD-017 | Completion threshold (N-of-N) — Same: plan-based completion doesn't need consensus. |
| RD-018 | Test-only loop detection — Not observed in RUN-001. Theoretical. |
| RD-019 | Two-stage error filtering — Ralph doesn't grep output for errors. Not applicable. |
| RD-020 | Rolling window signal tracking — Overkill at current scale (14 tasks, <30 iterations). |
| RD-021 | Five quality gates pipeline — Too prescriptive. Current validation gate + circuit breaker covers this. |
| RD-023 | Configurable error handling strategy — Already has strict/lenient/tests_only + per-task max_retries. |
| RD-037 | CI-gated iteration verification — Out of scope for local runs. Relevant when Ralph drives CI. |
| RD-039 | Line-range file references in handoffs — Optimization. Context agent already handles this via Read tools. |
| RD-040 | Handoff drift detection on resume — Theoretical. Ralph always runs on a clean state. |
| RD-041 | Spec-driven phase progression — Overkill. Plan.json dependencies already sequence work. |
| RD-048 | Output buffer limits — Theoretical. No observed memory issues. |
| RD-049 | Layered configuration system — Single ralph.conf + CLI flags is sufficient. |
| RD-050 | Task-file locking for parallel agents — Ralph runs single-agent. Not needed until parallel execution. |

## The Actual #1 Problem: Structured Handoff Enforcement

**None of the 50 patterns directly address RUN-001's critical issue.** The patterns assume the agent CAN produce structured output. Ralph's problem is that `claude -p --json-schema` doesn't enforce JSON when the agent does heavy tool use. The agent writes code, runs tests, then wraps up conversationally.

This needs a custom solution before the pattern list matters. Three approaches:

| Approach | Mechanism | Pros | Cons |
|----------|-----------|------|------|
| **A: Stronger footer** | Emphatic JSON reminder at end of `coding-prompt-footer.md` | Zero effort, test in next run | May still be ignored during heavy tool use |
| **B: Extraction pass** | After coding agent finishes, run a lightweight agent (Haiku) that reads the conversational output + git diff and produces the structured JSON | Guarantees structured output. Captures all signal fields. | Extra API call per iteration (~$0.01). Adds ~30s latency. |
| **C: Reduce max_turns** | Lower from 200 → 150 to force earlier output | Might help indirectly | Risk: agent runs out of turns before completing work |

**Recommended: A + B combined.** Strengthen the footer (free), and add a handoff extraction pass as fallback when JSON parsing fails. This replaces the current synthetic handoff (git metadata only) with a rich extraction (agent's actual narrative + structured fields). The extraction agent is a perfect fit for the existing agent-pass framework in `agents.json`.

## Recommended Implementation Waves

### Wave 0: Fix the feedback loop (before next run)
**Goal**: Get structured handoffs flowing so the feedback loop works.

1. **Strengthen coding-prompt-footer.md** — Add emphatic final reminder with exact JSON structure expected
2. **Add handoff extraction pass** — New agent pass (Haiku model, `on_synthetic_handoff` trigger) that reads the coding agent's raw output + git diff and produces schema-conformant JSON. Wire into `agents.sh` as a fallback before synthetic generation.
3. **Route human hints to prompt** (RD-007 upgrade) — Make `inject-note` content available to context prep agent, not just telemetry

**Files**: `.ralph/templates/coding-prompt-footer.md`, `.ralph/lib/agents.sh`, `.ralph/lib/cli-ops.sh`, `.ralph/config/agents.json`, `.ralph/lib/telemetry.sh`

### Wave 1: Safety nets (after feedback loop works)
**Goal**: Prevent runaway loops and wasted iterations.

4. **Failed-approaches log** (RD-001) — Append-only `.ralph/failed-approaches.md`. On validation failure, extract what was tried + why it failed. Inject into prompt §2.
5. **Active circuit breaker** (RD-003) — JSON state in `.ralph/circuit-breaker.json`. Track consecutive no-progress (no file changes) and consecutive same-error (hash validation output). CLOSED → OPEN at threshold. Auto-skip task when OPEN.
6. **Exponential backoff** (RD-008 upgrade) — Scale `RALPH_MIN_DELAY_SECONDS` by `2^retry_count`
7. **Max runtime cap** (RD-035) — `START_TIME` at loop entry, check before each iteration
8. **Blocked signal** (RD-022) — Check for `.ralph/BLOCKED.md` after each iteration

**Files**: `.ralph/lib/context.sh` or `.ralph/lib/agents.sh`, `.ralph/ralph.sh`, `.ralph/lib/validation.sh`

### Wave 2: Quality and observability (incremental)
**Goal**: Improve output quality and operator experience.

9. **Activate cross-model review** (RD-006/RD-012) — Enable the existing review agent skeleton with Haiku model, `on_success` trigger, SHIP/REVISE protocol
10. **Guardrails-as-signs** (RD-014) — `.ralph/guardrails.md` populated from recurring failures, injected early in prompt
11. **Cost/duration budget** (RD-015 upgrade) — Accumulate costs in state.json, enforce `RALPH_MAX_COST_USD`
12. **Per-task max_turns** (RD-034 upgrade) — Allow in plan.json task schema
13. **Completion notifications** (RD-045) — `osascript` notification on macOS when run completes

**Files**: `.ralph/config/agents.json`, `.ralph/lib/agents.sh`, `.ralph/ralph.sh`, `.ralph/lib/cli-ops.sh`

### Wave 3: Scope safety (when needed)
**Goal**: Prevent scope creep on larger projects.

14. **Task size validation** (RD-032) — Warn on tasks with >5 acceptance criteria or >200-word descriptions
15. **Scoped permissions** (RD-033) — Per-task `allowedTools` in plan.json, passed to `--allowedTools`
16. **Stale task recovery** (RD-016 upgrade) — Timestamp-based reset of `in_progress` tasks
17. **Append-system-prompt for immutable rules** (RD-036) — Behavioral constraints that survive context pressure

## Verification Strategy

After each wave:
1. Run `bash test-harness/loop.sh` (setup → run → analyze)
2. Compare against previous run in LOGBOOK.md
3. Key metrics to track:
   - **Wave 0**: Structured handoff rate (target: >80%, was 0%)
   - **Wave 1**: Tasks completed per retry count; circuit breaker triggers
   - **Wave 2**: Review agent verdicts; cost per task
   - **Wave 3**: Permission violations caught; task size warnings

## Summary: 50 patterns → 17 worth implementing

| Category | Skip | Upgrade | Add | Defer | Total |
|----------|------|---------|-----|-------|-------|
| VER (verification) | 4 | 0 | 1 | 4 | 9 |
| CTX (context) | 8 | 1 | 2 | 2 | 13 |
| ORC (orchestration) | 3 | 5 | 3 | 4 | 15 |
| QUA (quality) | 1 | 0 | 2 | 0 | 3 |
| PLN (planning) | 2 | 1 | 1 | 1 | 5 |
| SCO (scope) | 0 | 1 | 1 | 1 | 3 |
| DOC (documentation) | 1 | 0 | 0 | 1 | 2 |
| **Total** | **19** | **8** | **10** | **13** | **50** |

Ralph already covers ~38% of the ecosystem patterns. The 17 remaining items group naturally into 4 waves, with Wave 0 (fix structured handoffs) being the clear blocker for everything else.
