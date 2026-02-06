# Ralph Deluxe

A bash orchestrator that drives Claude Code CLI through structured task plans with memory compaction, git-backed rollback, and validation gates.

Ralph Deluxe reads a `plan.json` containing ordered tasks, executes them one at a time via `claude -p`, validates the results, and commits or rolls back using git. Between coding iterations, a memory-compaction agent compresses accumulated context into structured summaries so each iteration receives focused, relevant context rather than an ever-growing history.

## Features

- **Structured task plan execution** -- Tasks defined in `plan.json` with dependencies, acceptance criteria, and retry limits
- **Alternating coding and memory-compaction iterations** -- Coding agents do the work; memory agents compress the context
- **Three-tier context compaction (L1/L2/L3)** -- One-line summaries, key decisions, and full handoff documents at different granularities
- **Git-backed checkpoint and rollback** -- Every iteration starts with a checkpoint; failed iterations are fully rolled back
- **Configurable validation gates** -- Three strategies: `strict` (all checks pass), `lenient` (tests pass, lint warnings OK), `tests_only`
- **Plan mutation with safety guardrails** -- The coding agent can suggest plan changes (max 3 per iteration, cannot remove done tasks)
- **Skills injection system** -- Task-specific knowledge injected via markdown skill files
- **MCP isolation** -- Coding iterations use built-in tools only; memory iterations get Context7 and Knowledge Graph Memory Server
- **Rate limit protection** -- Configurable delay between iterations and max-turns caps

## Prerequisites

- **bash** 4.0+
- **jq** (JSON processing)
- **git** (version control)
- **Claude Code CLI** (`claude`) with an active Max subscription
- **bats-core** (for running tests)
- **shellcheck** (for linting, optional)

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
--dry-run            Print what would happen without executing
--resume             Resume from saved state
-h, --help           Show help
```

## Configuration

All settings live in `.ralph/config/ralph.conf`. Key settings:

| Setting | Default | Description |
|---------|---------|-------------|
| `RALPH_MAX_ITERATIONS` | 50 | Maximum iterations before stopping |
| `RALPH_VALIDATION_STRATEGY` | strict | Validation mode: `strict`, `lenient`, `tests_only` |
| `RALPH_COMPACTION_INTERVAL` | 5 | Coding iterations between memory compactions |
| `RALPH_COMPACTION_THRESHOLD_BYTES` | 32000 | Byte threshold to trigger compaction (~8000 tokens) |
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
│   ├── lib/                         # Helper modules
│   │   ├── context.sh               # Context assembly functions
│   │   ├── validation.sh            # Validation gate functions
│   │   ├── git-ops.sh               # Git checkpoint/rollback functions
│   │   ├── plan-ops.sh              # Plan reading/mutation functions
│   │   └── compaction.sh            # Compaction trigger/logic functions
│   ├── config/
│   │   ├── mcp-coding.json          # MCP config for coding iterations
│   │   ├── mcp-memory.json          # MCP config for memory iterations
│   │   ├── handoff-schema.json      # JSON Schema for handoff output
│   │   ├── memory-output-schema.json # JSON Schema for memory agent output
│   │   └── ralph.conf               # Environment/project configuration
│   ├── templates/
│   │   ├── coding-prompt.md         # Coding iteration prompt template
│   │   ├── memory-prompt.md         # Memory agent prompt template
│   │   └── first-iteration.md       # Special prompt for iteration 1
│   ├── skills/                      # Per-task skill injection files
│   │   ├── bash-conventions.md
│   │   ├── testing-bats.md
│   │   ├── jq-patterns.md
│   │   ├── mcp-config.md
│   │   └── git-workflow.md
│   ├── handoffs/                    # Raw handoff JSON from each iteration
│   ├── context/                     # Compacted context files
│   │   └── compaction-history/      # Previous compaction outputs
│   ├── logs/                        # Orchestrator logs
│   │   ├── ralph.log                # Main log
│   │   ├── amendments.log           # Plan amendment audit trail
│   │   └── validation/              # Per-iteration validation results
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
│   └── validation.bats
├── examples/
│   └── sample-project-plan.json     # Example plan for reference
├── CLAUDE.md                        # Project conventions for Claude Code
└── README.md
```

## How It Works

Each iteration follows this cycle:

1. **Read next task** -- Find the first pending task in `plan.json` whose dependencies are satisfied
2. **Check compaction trigger** -- If the context has grown large enough (byte threshold, iteration count, or task metadata requesting docs), run a memory-compaction iteration first
3. **Assemble context** -- Build the coding prompt from the task description, compacted context, previous handoff summary, and skill files, respecting token budgets
4. **Create git checkpoint** -- Capture `HEAD` so the iteration can be rolled back
5. **Run coding iteration** -- Invoke `claude -p` with structured output schema, MCP isolation, and skills injection
6. **Parse handoff** -- Extract the structured handoff JSON from the response
7. **Run validation** -- Execute configured validation commands (tests, linting)
8. **Commit or rollback** -- On pass: `git add -A && git commit`. On fail: `git reset --hard` to the checkpoint
9. **Apply amendments** -- If the handoff includes plan amendments (max 3), apply them with safety checks
10. **Loop** -- Continue to the next iteration or exit if all tasks are done

### Compaction Triggers

Memory compaction runs when any of these conditions are met:

- **Task metadata** -- The next task has `needs_docs: true` or non-empty `libraries`
- **Byte threshold** -- Accumulated handoff bytes since last compaction exceed 32KB (~8000 tokens)
- **Periodic** -- 5 coding iterations since the last compaction

### Context Hierarchy

| Level | Size | Content | Injected When |
|-------|------|---------|---------------|
| L1 | ~20-50 tokens | One-line summary per iteration | As rolling history (last 3) |
| L2 | ~200-500 tokens | Key decisions, constraints, bugs | Previous iteration only |
| L3 | ~500-2000 tokens | Full handoff document | Stored in handoffs/, not injected directly |

The memory agent compresses L2/L3 data into a structured compacted context that replaces individual entries.

## Testing

Run the full test suite:

```bash
bats tests/
```

Run a specific test file:

```bash
bats tests/integration.bats
bats tests/error-handling.bats
bats tests/git-ops.bats
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
