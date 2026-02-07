# Ralph Deluxe

A bash orchestrator that drives Claude Code CLI through structured task plans with handoff-first context management, git-backed rollback, validation gates, and an operator dashboard.

Ralph Deluxe reads a `plan.json` containing ordered tasks, executes them one at a time via `claude -p`, validates the results, and commits or rolls back using git. Each coding iteration writes a freeform handoff narrative — the LLM's own oriented briefing for whoever picks up next — which becomes the primary context for the following iteration.

## Features

- **Handoff-first context management** -- Each iteration writes a freeform narrative briefing. The handoff IS the memory — no separate summarization needed in the default mode
- **Two operating modes** -- `handoff-only` (default, zero overhead) and `handoff-plus-index` (adds a knowledge indexer that maintains a categorized index across iterations)
- **Structured task plan execution** -- Tasks defined in `plan.json` with dependencies, acceptance criteria, and retry limits
- **Git-backed checkpoint and rollback** -- Every iteration starts with a checkpoint; failed iterations are fully rolled back
- **Configurable validation gates** -- Three strategies: `strict` (all checks pass), `lenient` (tests pass, lint warnings OK), `tests_only`
- **Plan mutation with safety guardrails** -- The coding agent can suggest plan changes (max 3 per iteration, cannot remove done tasks)
- **Skills injection system** -- Task-specific knowledge injected via markdown skill files
- **MCP isolation** -- Coding iterations use built-in tools only; memory iterations get Context7 and Knowledge Graph Memory Server
- **Telemetry and event logging** -- Append-only JSONL event stream for monitoring iteration lifecycle
- **Operator dashboard** -- Single-file HTML dashboard with real-time metrics, handoff viewer, control plane (pause/resume, inject notes, skip tasks), and settings
- **Rate limit protection** -- Configurable delay between iterations and max-turns caps

## Prerequisites

- **bash** 4.0+
- **jq** (JSON processing)
- **git** (version control)
- **Claude Code CLI** (`claude`) with an active Max subscription
- **bats-core** (for running tests)
- **shellcheck** (for linting, optional)
- **Python 3** (for the dashboard server, optional)

## Quick Start

1. Clone this repository and navigate to the project root.

2. Create a `plan.json` with your tasks (see [Plan Format](#plan-format) below or the example in `examples/`).

3. Review and adjust `.ralph/config/ralph.conf` for your project:
   ```bash
   # Set your validation commands
   RALPH_VALIDATION_COMMANDS=("npm test" "eslint src/")
   ```

4. Run the orchestrator:
   ```bash
   bash .ralph/ralph.sh --plan plan.json
   ```

5. For a dry run (processes tasks without invoking Claude or modifying git):
   ```bash
   bash .ralph/ralph.sh --plan plan.json --dry-run
   ```

### CLI Options

```
--max-iterations N   Maximum iterations to run (default: 50)
--plan FILE          Path to plan.json (default: plan.json)
--config FILE        Path to ralph.conf
--mode MODE          Operating mode: handoff-only (default) or handoff-plus-index
--dry-run            Print what would happen without executing
--resume             Resume from saved state
-h, --help           Show help
```

## Operating Modes

Ralph Deluxe supports two operating modes, selected via the `--mode` flag or `RALPH_MODE` in `ralph.conf`.

### `handoff-only` (default)

Each coding iteration writes a freeform handoff narrative. The next iteration receives that narrative as its primary context. No compaction iterations run. No knowledge index is maintained.

This is the simplest mode: the handoff IS the memory. Zero overhead, no extra iterations, no accumulated index to manage.

```bash
bash .ralph/ralph.sh --plan plan.json --mode handoff-only
```

### `handoff-plus-index`

Same as `handoff-only`, but periodically runs a knowledge indexer pass that reads recent handoffs and maintains two files:

- `.ralph/knowledge-index.md` -- Categorized index (constraints, architectural decisions, patterns, gotchas) for the coding LLM to consult
- `.ralph/knowledge-index.json` -- Iteration-keyed entries for the dashboard's Knowledge Index table

The coding prompt includes a pointer to `knowledge-index.md` so the LLM can read it if it needs project history beyond the most recent handoff.

```bash
bash .ralph/ralph.sh --plan plan.json --mode handoff-plus-index
```

The knowledge indexer triggers under the same conditions as the legacy compaction system: periodic interval (default every 5 coding iterations) or byte threshold (default 32KB of accumulated handoffs).

## Dashboard

Ralph Deluxe includes a single-file HTML dashboard for monitoring and controlling the orchestrator in real time.

### Starting the dashboard

The dashboard requires an HTTP server because it reads local files via fetch and writes control commands via POST. A purpose-built server is included:

```bash
# From the project root:
python3 .ralph/serve.py --port 8080

# Then open in your browser:
# http://localhost:8080/.ralph/dashboard.html
```

The server serves all project files (state, handoffs, events) and provides POST endpoints for dashboard control actions.

### Dashboard panels

- **Metrics strip** -- Iteration count, tasks completed, validation pass/fail counts, rollbacks, current mode, and orchestrator status
- **Task plan** -- Full task list with status badges and current-task highlighting. Pending tasks have skip buttons
- **Handoff viewer** -- Browse all handoff documents. Shows the freeform narrative (primary view), plus structured fields: deviations, constraints, architecture notes, and files touched
- **Knowledge index** -- Table view of the knowledge index (iteration, task, summary, tags). Active in `handoff-plus-index` mode
- **Git timeline** -- Visual timeline of iterations with pass/fail/running states
- **Event log** -- Live stream of the last 50 telemetry events, color-coded by type
- **Architecture diagram** -- ASCII diagrams showing the data flow for each mode

### Control plane

The dashboard can send commands to the orchestrator. Commands are queued in `.ralph/control/commands.json` and processed at the top of each iteration.

- **Pause/resume** -- Pause the orchestrator between iterations. It polls for a resume command
- **Inject note** -- Send a text note that appears in the event log. Useful for recording operator observations
- **Skip task** -- Mark a pending task as skipped so the orchestrator moves past it
- **Settings** -- Adjust mode, validation strategy, compaction interval, max turns, and delay between iterations

## Configuration

All settings live in `.ralph/config/ralph.conf`. Key settings:

| Setting | Default | Description |
|---------|---------|-------------|
| `RALPH_MAX_ITERATIONS` | 50 | Maximum iterations before stopping |
| `RALPH_MODE` | handoff-only | Operating mode: `handoff-only` or `handoff-plus-index` |
| `RALPH_VALIDATION_STRATEGY` | strict | Validation mode: `strict`, `lenient`, `tests_only` |
| `RALPH_COMPACTION_INTERVAL` | 5 | Coding iterations between knowledge indexer passes (handoff-plus-index only) |
| `RALPH_COMPACTION_THRESHOLD_BYTES` | 32000 | Byte threshold to trigger knowledge indexing (~8000 tokens) |
| `RALPH_DEFAULT_MAX_TURNS` | 20 | Default max turns per coding iteration |
| `RALPH_MIN_DELAY_SECONDS` | 30 | Minimum delay between iterations (rate limit protection) |
| `RALPH_CONTEXT_BUDGET_TOKENS` | 8000 | Token budget for assembled context prompts |
| `RALPH_COMMIT_PREFIX` | ralph | Prefix for git commit messages |
| `RALPH_LOG_LEVEL` | info | Log verbosity: `debug`, `info`, `warn`, `error` |
| `RALPH_VALIDATION_COMMANDS` | (array) | Shell commands to run for validation |

See `.ralph/config/ralph.conf` for the full annotated configuration.

## Directory Structure

```
project-root/
├── .ralph/                          # Orchestrator runtime directory
│   ├── ralph.sh                     # Main orchestrator script
│   ├── serve.py                     # Dashboard HTTP server
│   ├── dashboard.html               # Operator dashboard (single-file)
│   ├── lib/                         # Helper modules
│   │   ├── cli-ops.sh               # Claude CLI invocation wrappers
│   │   ├── context.sh               # Context/prompt assembly functions
│   │   ├── validation.sh            # Validation gate functions
│   │   ├── git-ops.sh               # Git checkpoint/rollback functions
│   │   ├── plan-ops.sh              # Plan reading/mutation functions
│   │   ├── compaction.sh            # Compaction + knowledge indexer functions
│   │   └── telemetry.sh             # Event logging + control command processing
│   ├── config/
│   │   ├── mcp-coding.json          # MCP config for coding iterations
│   │   ├── mcp-memory.json          # MCP config for memory/indexer iterations
│   │   ├── handoff-schema.json      # JSON Schema for handoff output
│   │   ├── memory-output-schema.json # JSON Schema for memory agent output
│   │   └── ralph.conf               # Environment/project configuration
│   ├── templates/
│   │   ├── coding-prompt.md         # Coding iteration prompt template
│   │   ├── memory-prompt.md         # Memory agent prompt template
│   │   ├── knowledge-index-prompt.md # Knowledge indexer prompt template
│   │   └── first-iteration.md       # Special prompt for iteration 1
│   ├── skills/                      # Per-task skill injection files
│   │   ├── bash-conventions.md
│   │   ├── testing-bats.md
│   │   ├── jq-patterns.md
│   │   ├── mcp-config.md
│   │   └── git-workflow.md
│   ├── handoffs/                    # Raw handoff JSON from each iteration
│   ├── context/                     # Compacted context files (legacy)
│   │   └── compaction-history/      # Previous compaction outputs
│   ├── control/
│   │   └── commands.json            # Dashboard → orchestrator command queue
│   ├── logs/                        # Orchestrator logs
│   │   ├── ralph.log                # Main log
│   │   ├── events.jsonl             # Telemetry event stream
│   │   ├── amendments.log           # Plan amendment audit trail
│   │   └── validation/              # Per-iteration validation results
│   ├── knowledge-index.md           # Categorized knowledge index (LLM-readable)
│   ├── knowledge-index.json         # Iteration-keyed index (dashboard-readable)
│   ├── memory.jsonl                 # Knowledge Graph Memory Server data
│   └── state.json                   # Orchestrator runtime state
├── plan.json                        # Task plan (project root)
├── tests/                           # bats-core test suite
│   ├── test_helper/
│   │   └── common.sh                # Shared test helpers
│   ├── fixtures/                    # Test fixtures
│   ├── integration.bats
│   ├── error-handling.bats
│   ├── git-ops.bats
│   ├── plan-ops.bats
│   ├── context.bats
│   ├── compaction.bats
│   ├── telemetry.bats
│   ├── cli-ops.bats
│   └── validation.bats
├── examples/
│   └── sample-project-plan.json     # Example plan for reference
├── CLAUDE.md                        # Project conventions for Claude Code
└── README.md
```

## How It Works

Each iteration follows this cycle:

1. **Process control commands** -- Check for pause/resume/skip-task/inject-note commands from the dashboard
2. **Read next task** -- Find the first pending task in `plan.json` whose dependencies are satisfied
3. **Check knowledge indexer** -- In `handoff-plus-index` mode, if thresholds are met, run the knowledge indexer pass
4. **Assemble context** -- Build the coding prompt: task description, previous handoff narrative, skills, and (in `handoff-plus-index` mode) a pointer to the knowledge index
5. **Create git checkpoint** -- Capture `HEAD` so the iteration can be rolled back
6. **Run coding iteration** -- Invoke `claude -p` with structured output schema, MCP isolation, and skills injection
7. **Parse handoff** -- Extract the structured handoff JSON (including the freeform narrative)
8. **Run validation** -- Execute configured validation commands (tests, linting)
9. **Commit or rollback** -- On pass: `git add -A && git commit`. On fail: `git reset --hard` to the checkpoint
10. **Apply amendments** -- If the handoff includes plan amendments (max 3), apply them with safety checks
11. **Emit telemetry** -- Log iteration result to the event stream
12. **Loop** -- Continue to the next iteration or exit if all tasks are done

### Handoff Schema

Each coding iteration outputs a structured handoff document. The two most important fields are:

- **`summary`** -- One-line description of what was accomplished (used by the orchestrator for logging and the knowledge index)
- **`freeform`** -- Full narrative briefing for the next iteration. This is the primary artifact that travels forward

Additional structured fields (`task_completed`, `deviations`, `bugs_encountered`, `architectural_notes`, `constraints_discovered`, `files_touched`, `plan_amendments`, `tests_added`) support orchestrator bookkeeping, validation, and plan mutation.

### Knowledge Indexer (handoff-plus-index mode)

In `handoff-plus-index` mode, the orchestrator periodically runs a knowledge indexer pass that:

1. Reads all handoffs since the last indexing pass
2. Updates `.ralph/knowledge-index.md` with categorized entries (constraints, decisions, patterns, gotchas, unresolved issues)
3. Updates `.ralph/knowledge-index.json` with per-iteration entries for the dashboard

The indexer triggers on the same conditions as the legacy compaction system: periodic interval or byte threshold.

### Telemetry

The orchestrator emits structured events to `.ralph/logs/events.jsonl`. Each event has:

```json
{"timestamp": "...", "event": "iteration_start", "message": "...", "metadata": {...}}
```

Event types: `orchestrator_start`, `orchestrator_end`, `iteration_start`, `iteration_end`, `validation_pass`, `validation_fail`, `pause`, `resume`, `note`, `skip_task`.

The dashboard reads this file to render the event log and compute metrics.

## Testing

Run the full test suite:

```bash
bats tests/
```

Run a specific test file:

```bash
bats tests/integration.bats
bats tests/telemetry.bats
bats tests/context.bats
```

Run shellcheck on all bash files:

```bash
shellcheck .ralph/ralph.sh .ralph/lib/*.sh
```

## Plan Format

The `plan.json` file defines your project tasks:

```json
{
  "project": "my-project",
  "branch": "feature/my-feature",
  "max_iterations": 50,
  "validation_strategy": "strict",
  "tasks": [
    {
      "id": "TASK-001",
      "title": "Create project scaffold",
      "description": "Set up directory structure and config files.",
      "status": "pending",
      "order": 1,
      "skills": ["bash-conventions"],
      "needs_docs": false,
      "libraries": [],
      "acceptance_criteria": [
        "All directories exist",
        "Config files are valid JSON"
      ],
      "depends_on": [],
      "max_turns": 15,
      "retry_count": 0,
      "max_retries": 2
    }
  ]
}
```

### Task Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique task identifier (e.g., `TASK-001`) |
| `title` | string | Short task title |
| `description` | string | Detailed description of what to implement |
| `status` | string | `pending`, `in_progress`, `done`, `failed`, `skipped` |
| `order` | number | Execution order |
| `skills` | string[] | Skill files to inject (maps to `.ralph/skills/{name}.md`) |
| `needs_docs` | boolean | If true, triggers memory iteration with Context7 |
| `libraries` | string[] | Libraries to fetch docs for via Context7 |
| `acceptance_criteria` | string[] | Conditions that must be met |
| `depends_on` | string[] | Task IDs that must be `done` before this task starts |
| `max_turns` | number | Maximum Claude Code turns for this task |
| `retry_count` | number | Current retry count (managed by orchestrator) |
| `max_retries` | number | Maximum retries before marking as `failed` |

See `examples/sample-project-plan.json` for a complete example.

## v2 Design Rationale

Ralph Deluxe v2 added three things to the original orchestrator:

1. **Handoff narrative** -- A freeform `summary` + `freeform` field in the handoff schema. The coding LLM writes an oriented briefing for whoever picks up next. This replaced the structured-fields-only handoff with a narrative that carries forward as the primary context.

2. **Selectable mode** -- `handoff-only` (narrative IS the memory, no overhead) vs. `handoff-plus-index` (narrative + periodic knowledge indexer). The default is `handoff-only` because the narrative alone is sufficient for most workflows.

3. **Dashboard + control plane** -- A single-file HTML dashboard that reads telemetry events, handoffs, and state files for monitoring, plus a control plane (via `serve.py`) for pause/resume, note injection, task skipping, and settings changes.

The original L1/L2/L3 compaction system and context hierarchy remain in the codebase for backward compatibility but are superseded by the handoff-first approach in both modes.

For the full v2 design specification, see `ralph-deluxe-v2-revision-plan 2.md`.
