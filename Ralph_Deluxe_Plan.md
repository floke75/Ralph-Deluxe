# Ralph loop orchestration: complete implementation plan

**The system is a ~400-line bash orchestrator that drives Claude Code CLI through a structured task plan, alternating between coding iterations and memory-compaction iterations, with git-backed rollback, validation gates, and hierarchical context management.** This plan specifies every component, schema, and implementation phase so Claude Code can self-build the system in approximately 12 sequential sessions. The design prioritizes bash simplicity and LLM-implementability throughout — every technology scores above minimum thresholds on the DD-22-01 framework, and the highest-risk components (MCP configuration, structured output parsing) receive the most detailed specification.

Three critical corrections emerged from research: the `quantsquirrel/claude-handoff` repository does not exist publicly, so the L1/L2/L3 compaction scheme is designed from scratch using community patterns; Claude Code's `--agents` flag now supports inline subagent definitions, offering a potential simplification path; and rate limits on Max $200/month are shared across web and CLI usage with 5-hour rolling windows, making iteration budgeting essential.

---

## 1. Component architecture and system design

### 1.1 The bash orchestrator (`ralph.sh`)

The main loop is a single bash script under 500 lines. It executes one `claude -p` call per iteration, alternating between two modes:

**Coding mode** (default): Assembles context entirely via bash (`cat`, `jq`, heredocs), pipes it to `claude -p` with the coding MCP config, captures structured handoff output via `--json-schema`, runs validation, and commits or rolls back.

**Memory mode** (triggered conditionally): Invokes `claude -p` with a different MCP config (`--strict-mcp-config --mcp-config memory-mcp.json`) that includes Context7 and the Knowledge Graph Memory Server. The memory agent reads accumulated handoff documents, compresses them into L1/L2 summaries, optionally queries library docs, and outputs a structured context package via `--json-schema`. This output is saved as `context/compacted-context.json` and injected into subsequent coding iterations.

The orchestrator never uses the API — all invocations run on the Claude Max subscription via CLI. Each iteration uses `--dangerously-skip-permissions` for unattended operation, `--append-system-prompt-file` for skills injection, and `--max-turns` as a safety cap.

```
┌─────────────────────────────────────────────────┐
│                  ralph.sh                        │
│                                                  │
│  1. Read plan.json → find next pending task      │
│  2. Check compaction trigger                     │
│  3. If trigger → run memory iteration            │
│  4. Assemble context (bash-only)                 │
│  5. Create git checkpoint                        │
│  6. Run claude -p (coding iteration)             │
│  7. Parse structured handoff output              │
│  8. Run validation gate                          │
│  9. If pass → commit, mark task done             │
│     If fail → git rollback, log failure          │
│  10. Apply plan amendments (if any)              │
│  11. Loop or exit                                │
└─────────────────────────────────────────────────┘
```

### 1.2 The task plan format (`plan.json`)

A flat JSON file with ordered tasks. Each task specifies its scope, acceptance criteria, dependencies, required skills, and optional metadata for library documentation needs:

```json
{
  "project": "compass",
  "branch": "feature/ralph-orchestrator",
  "max_iterations": 50,
  "validation_strategy": "strict",
  "tasks": [
    {
      "id": "TASK-001",
      "title": "Create directory structure and config files",
      "description": "Set up the project scaffold per the directory layout spec.",
      "status": "pending",
      "order": 1,
      "skills": ["bash-conventions"],
      "needs_docs": false,
      "libraries": [],
      "acceptance_criteria": [
        "All directories from the spec exist",
        "Config JSON files are valid JSON",
        "Template files contain placeholder markers"
      ],
      "depends_on": [],
      "max_turns": 15,
      "retry_count": 0,
      "max_retries": 2
    }
  ]
}
```

**Status values**: `pending`, `in_progress`, `done`, `failed`, `skipped`. The orchestrator sets `in_progress` before running and `done` or `failed` after validation.

### 1.3 The handoff document schema

Each coding iteration outputs structured JSON via `--json-schema`. The orchestrator extracts this from `--output-format json` via `jq '.structured_output'`. Full schema defined in Section 7.

### 1.4 The context injection template

Coding iterations receive a prompt assembled from multiple sections, each with a token budget. The template uses heredoc concatenation in bash:

```bash
build_coding_prompt() {
    local task_json="$1"
    local compacted_context="$2"
    local prev_handoff="$3"
    local skills_content="$4"

    cat <<PROMPT
## Current Task
$(echo "$task_json" | jq -r '"ID: \(.id)\nTitle: \(.title)\n\nDescription:\n\(.description)\n\nAcceptance Criteria:\n" + (.acceptance_criteria | map("- " + .) | join("\n"))')

## Project Context (Compacted)
${compacted_context:-"No compacted context available. This is an early iteration."}

## Previous Iteration Summary
${prev_handoff:-"No previous iteration."}

## Skills & Conventions
${skills_content}

## Output Requirements
You MUST produce a handoff document as your final output. Structure your response as valid JSON matching the handoff schema provided via --json-schema.
After implementing, run the acceptance criteria checks yourself before producing the handoff.
PROMPT
}
```

### 1.5 Compaction logic

Three triggers, checked in order before each coding iteration:

1. **Task-metadata-driven** (highest priority): If the next task has `needs_docs: true` or non-empty `libraries`, trigger a full memory iteration with Context7 queries
2. **Threshold-based**: If the combined size of all L3 handoff files since last compaction exceeds **8,000 tokens** (~32KB of JSON), trigger compaction
3. **Periodic fallback**: Every **5 coding iterations** since the last compaction, trigger compaction regardless

Token estimation uses the approximation **1 token ≈ 4 characters** for sizing decisions. The orchestrator measures file sizes in bytes and divides by 4.

### 1.6 The skills mapping system

Task metadata includes `skills: ["bash-conventions", "testing-bats"]` which maps to markdown files in `skills/`. The orchestrator concatenates matching skill files and injects them via `--append-system-prompt-file` or inline in the prompt:

```bash
load_skills() {
    local task_json="$1"
    local skills_dir="skills"
    local combined=""
    
    for skill in $(echo "$task_json" | jq -r '.skills[]'); do
        local skill_file="${skills_dir}/${skill}.md"
        if [ -f "$skill_file" ]; then
            combined+="$(cat "$skill_file")"$'\n\n'
        fi
    done
    echo "$combined"
}
```

### 1.7 The validation gate

Runs after each coding iteration. Configurable per-project via `validation.json`:

```bash
run_validation() {
    local iteration="$1"
    local pass=true
    
    # Run each configured check
    if [ -f "package.json" ]; then
        npm test 2>&1 || pass=false
    fi
    
    if command -v shellcheck &>/dev/null; then
        shellcheck ralph.sh 2>&1 || pass=false
    fi
    
    # Bats tests for the orchestrator itself
    if [ -d "tests" ]; then
        bats tests/ 2>&1 || pass=false
    fi
    
    [ "$pass" = true ]
}
```

The strategy field in `plan.json` controls strictness: `strict` (all checks must pass), `lenient` (tests must pass, lint warnings OK), or `tests_only`.

### 1.8 Git rollback mechanism

Uses the **commit-and-reset pattern**, not stash. Before each iteration, the orchestrator captures `CHECKPOINT=$(git rev-parse HEAD)`. On validation failure:

```bash
git reset --hard "$CHECKPOINT"
git clean -fd  # Remove untracked files created during failed iteration
```

On validation success:

```bash
git add -A
git commit -m "ralph[${ITERATION}]: ${TASK_ID} — passed validation"
```

This creates a clean, linear git history where every commit represents a successful iteration.

### 1.9 Plan mutation acceptance logic

The agent's handoff JSON includes an optional `plan_amendments` array. The orchestrator processes amendments with safety guardrails:

- Maximum **3 amendments per iteration**
- Cannot remove tasks with status `done`
- Cannot modify the currently executing task's status
- New tasks must have `id`, `title`, and `description`
- All amendments are logged to `logs/amendments.log`
- Plan file is backed up before mutation (`plan.json.bak`)

Amendments are applied via `jq` after successful validation, using the patterns: array slicing for insertion (`[:idx+1] + [$task] + [idx+1:]`), `del()` for removal, and `map(if .id == $id then . + $changes else . end)` for modification.

### 1.10 MCP configuration files

Two separate config files, selected via `--strict-mcp-config`:

**`mcp-coding.json`** — Minimal toolset for coding iterations:
```json
{
  "mcpServers": {}
}
```
Coding iterations use Claude Code's built-in tools only (Read, Edit, Bash, Grep, Glob). No external MCP servers. This keeps the coding context clean and avoids MCP startup overhead.

**`mcp-memory.json`** — Full toolset for memory/compaction iterations:
```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp@latest"]
    },
    "memory": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-memory"],
      "env": {
        "MEMORY_FILE_PATH": ".ralph/memory.jsonl"
      }
    }
  }
}
```

The coding config uses `--strict-mcp-config --mcp-config mcp-coding.json` to ensure complete isolation. The memory config includes Context7 for library documentation queries and the Knowledge Graph Memory Server for persistent cross-session knowledge.

---

## 2. File and directory structure

```
project-root/
├── .ralph/                          # Orchestrator runtime directory
│   ├── ralph.sh                     # Main orchestrator script (~400 lines)
│   ├── lib/                         # Orchestrator helper functions
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
│   │   ├── handoff-001.json
│   │   ├── handoff-002.json
│   │   └── ...
│   ├── context/                     # Compacted context files
│   │   ├── compacted-latest.json    # Most recent compaction output
│   │   └── compaction-history/      # Previous compaction outputs
│   ├── logs/                        # Orchestrator logs
│   │   ├── ralph.log                # Main orchestrator log
│   │   ├── amendments.log           # Plan amendment audit trail
│   │   └── validation/              # Per-iteration validation results
│   ├── memory.jsonl                 # Knowledge Graph Memory Server data
│   └── state.json                   # Orchestrator runtime state
├── plan.json                        # Task plan (project root for visibility)
├── tests/                           # Orchestrator tests (bats-core)
│   ├── test_helper/
│   │   └── bats-support/            # bats-assert, bats-support libraries
│   ├── context.bats
│   ├── validation.bats
│   ├── git-ops.bats
│   ├── plan-ops.bats
│   └── compaction.bats
└── CLAUDE.md                        # Project-level Claude Code instructions
```

**`state.json`** tracks runtime state between iterations:
```json
{
  "current_iteration": 0,
  "last_compaction_iteration": 0,
  "coding_iterations_since_compaction": 0,
  "total_handoff_bytes_since_compaction": 0,
  "last_task_id": null,
  "started_at": "2026-02-06T10:00:00Z",
  "status": "idle"
}
```

---

## 3. Implementation phases for Claude Code

Each phase is sized for a single Claude Code session. Phases are ordered by dependency — foundations first.

### Phase 1: Project scaffold and configuration files

**Scope**: Create the directory structure, all configuration files, and JSON schemas.

**Tasks**:
- Create all directories in the file structure above
- Write `ralph.conf` with default environment variables
- Write `mcp-coding.json` and `mcp-memory.json`
- Write `handoff-schema.json` (the full JSON Schema from Section 7)
- Write `memory-output-schema.json`
- Write `state.json` with initial values
- Write a starter `plan.json` with Phase 2 as the first task
- Write `CLAUDE.md` with project conventions

**Acceptance criteria**: All files exist, all JSON files pass `jq . < file.json`, directory structure matches spec.

**Skills**: `["bash-conventions", "jq-patterns"]`

**Max turns**: 15

---

### Phase 2: Core orchestrator loop skeleton

**Scope**: Write `ralph.sh` with the main loop structure, argument parsing, and iteration flow — but stub out all helper functions.

**Tasks**:
- Parse CLI arguments (`--max-iterations`, `--plan`, `--config`, `--dry-run`)
- Read `state.json` for current iteration
- Main loop: read next pending task from `plan.json`, check completion, iterate
- Source helper scripts from `lib/`
- Signal handling (`trap` for SIGINT/SIGTERM — graceful shutdown)
- Logging to `logs/ralph.log`
- Stub functions: `build_coding_prompt`, `run_coding_iteration`, `run_memory_iteration`, `run_validation`, `create_checkpoint`, `rollback_checkpoint`, `apply_amendments`, `check_compaction_trigger`

**Acceptance criteria**: `bash -n ralph.sh` passes (syntax check), `shellcheck ralph.sh` passes, script runs in `--dry-run` mode without errors, stubs print placeholder messages.

**Skills**: `["bash-conventions"]`

**Max turns**: 20

---

### Phase 3: Git operations module

**Scope**: Implement `lib/git-ops.sh` with checkpoint and rollback functions.

**Tasks**:
- `create_checkpoint()`: Capture `git rev-parse HEAD`, return checkpoint hash
- `rollback_to_checkpoint()`: `git reset --hard $hash && git clean -fd`
- `commit_iteration()`: `git add -A && git commit -m "ralph[N]: TASK-ID — message"`
- `ensure_clean_state()`: Check for uncommitted changes at startup
- Error handling for all git operations

**Acceptance criteria**: bats tests pass covering checkpoint/rollback/commit cycle. Test creates files, checkpoints, makes changes, rolls back, verifies original state restored. New untracked files are cleaned up after rollback.

**Skills**: `["bash-conventions", "git-workflow", "testing-bats"]`

**Max turns**: 15

---

### Phase 4: Plan operations module

**Scope**: Implement `lib/plan-ops.sh` for reading tasks and applying mutations.

**Tasks**:
- `get_next_task()`: Return first task with `status: "pending"`, respecting `depends_on`
- `set_task_status()`: Update a task's status in `plan.json`
- `get_task_by_id()`: Retrieve a task's full JSON by ID
- `apply_amendments()`: Process `plan_amendments` array with safety guardrails (max 3, no removing done tasks, backup before mutation)
- `is_plan_complete()`: Check if all tasks are done
- `count_remaining_tasks()`: Return count of pending/failed tasks

**Acceptance criteria**: bats tests pass covering all operations. Tests verify: task retrieval respects dependency ordering, status updates persist, amendments add/remove/modify tasks correctly, safety guardrails block invalid amendments.

**Skills**: `["bash-conventions", "jq-patterns", "testing-bats"]`

**Max turns**: 20

---

### Phase 5: Context assembly module

**Scope**: Implement `lib/context.sh` for building coding and memory prompts.

**Tasks**:
- `build_coding_prompt()`: Assemble prompt from task JSON + compacted context + previous handoff summary + skills
- `load_skills()`: Read and concatenate skill files based on task metadata
- `get_prev_handoff_summary()`: Extract L1/L2 from most recent handoff
- `estimate_tokens()`: Approximate token count from character count (÷4)
- `truncate_to_budget()`: Trim sections to fit within token budgets
- Priority ordering: task description > acceptance criteria > skills > compacted context > previous handoff

**Acceptance criteria**: bats tests verify prompt assembly with various combinations of available context. Token estimation within 20% of manual count for sample inputs. Truncation preserves highest-priority content.

**Skills**: `["bash-conventions", "jq-patterns", "testing-bats"]`

**Max turns**: 15

---

### Phase 6: Validation gate module

**Scope**: Implement `lib/validation.sh` with configurable validation checks.

**Tasks**:
- `run_validation()`: Execute configured checks, capture results as JSON
- `evaluate_results()`: Apply validation strategy (strict/lenient/tests_only)
- `generate_failure_context()`: Create summary of failures for next iteration
- Support for: bats tests, shellcheck, npm test, custom commands
- Write results to `logs/validation/iter-N.json`

**Acceptance criteria**: bats tests verify each validation strategy. Tests mock failing/passing commands and verify correct pass/fail determination. Failure context includes truncated error output.

**Skills**: `["bash-conventions", "testing-bats"]`

**Max turns**: 15

---

### Phase 7: Compaction trigger and strategy module

**Scope**: Implement `lib/compaction.sh` with trigger logic and L1/L2/L3 extraction.

**Tasks**:
- `check_compaction_trigger()`: Evaluate three trigger conditions (task metadata, threshold, periodic)
- `extract_l1()`: One-line summary from handoff JSON
- `extract_l2()`: Key decisions, constraints, failed approaches from handoff
- `extract_l3()`: Full handoff document reference
- `build_compaction_input()`: Assemble all handoffs since last compaction for the memory agent
- `update_compaction_state()`: Reset counters after compaction

**Acceptance criteria**: bats tests verify all three trigger conditions. L1/L2/L3 extraction produces correctly structured output from sample handoff files. State counters reset correctly after compaction.

**Skills**: `["bash-conventions", "jq-patterns", "testing-bats"]`

**Max turns**: 15

---

### Phase 8: Claude Code CLI integration

**Scope**: Implement the actual `claude -p` invocation wrappers for both coding and memory iterations.

**Tasks**:
- `run_coding_iteration()`: Invoke `claude -p` with coding MCP config, structured output, skills injection, turn limits
- `run_memory_iteration()`: Invoke `claude -p` with memory MCP config, structured output, library queries
- `parse_handoff_output()`: Extract `structured_output` from JSON response via `jq`
- `save_handoff()`: Write handoff JSON to `handoffs/handoff-NNN.json`
- Error handling: detect CLI failures, timeout handling, empty response handling
- Rate limit awareness: log `duration_ms` and `num_turns` from response metadata

**Concrete invocation for coding iteration**:
```bash
run_coding_iteration() {
    local prompt="$1"
    local task_json="$2"
    local skills_file="$3"
    local max_turns
    max_turns=$(echo "$task_json" | jq -r '.max_turns // 20')
    
    local response
    response=$(echo "$prompt" | claude -p \
        --output-format json \
        --json-schema "$(cat .ralph/config/handoff-schema.json)" \
        --append-system-prompt-file "$skills_file" \
        --strict-mcp-config \
        --mcp-config .ralph/config/mcp-coding.json \
        --max-turns "$max_turns" \
        --dangerously-skip-permissions \
        2>/dev/null)
    
    echo "$response"
}
```

**Concrete invocation for memory iteration**:
```bash
run_memory_iteration() {
    local prompt="$1"
    
    local response
    response=$(echo "$prompt" | claude -p \
        --output-format json \
        --json-schema "$(cat .ralph/config/memory-output-schema.json)" \
        --strict-mcp-config \
        --mcp-config .ralph/config/mcp-memory.json \
        --max-turns 10 \
        --dangerously-skip-permissions \
        2>/dev/null)
    
    echo "$response"
}
```

**Acceptance criteria**: Dry-run mode works with mocked CLI responses. Response parsing correctly extracts structured output. Error states (empty response, CLI failure, invalid JSON) are handled gracefully. Integration test with real Claude Code CLI succeeds for a trivial task.

**Skills**: `["bash-conventions", "jq-patterns", "testing-bats"]`

**Max turns**: 25

---

### Phase 9: Wire everything together

**Scope**: Connect all modules in `ralph.sh`, remove stubs, implement the full iteration loop.

**Tasks**:
- Replace all stub functions with calls to module functions
- Implement the full iteration cycle: checkpoint → prompt assembly → CLI call → parse output → validate → commit/rollback → update state → check compaction → loop
- Implement graceful shutdown (save state on SIGINT)
- Add `--resume` flag to continue from saved state
- Add progress reporting to stdout

**Acceptance criteria**: Full end-to-end dry run completes without errors. Orchestrator correctly sequences coding and memory iterations. State file updates correctly across iterations. Graceful shutdown preserves state. Resume continues from correct iteration.

**Skills**: `["bash-conventions"]`

**Max turns**: 25

---

### Phase 10: Prompt templates and skill files

**Scope**: Write all markdown templates and skill files.

**Tasks**:
- Write `templates/coding-prompt.md` — the template with section markers
- Write `templates/memory-prompt.md` — instructions for the memory agent on how to compact, what to query from Context7, what to store in the knowledge graph
- Write `templates/first-iteration.md` — bootstrapping prompt for the very first iteration
- Write all skill files: `bash-conventions.md`, `testing-bats.md`, `jq-patterns.md`, `mcp-config.md`, `git-workflow.md`
- Each skill file should be **under 1,000 tokens** to fit within context budgets

**Acceptance criteria**: All template files exist and contain appropriate instructions. Skill files are under 4KB each. Templates use clear section markers that the context assembly code can find.

**Skills**: `[]` (this is content writing, no special skills needed)

**Max turns**: 15

---

### Phase 11: Comprehensive test suite

**Scope**: Write bats-core integration tests covering the full orchestrator.

**Tasks**:
- Integration test: full orchestrator cycle with mocked `claude` command
- Test compaction trigger logic with edge cases
- Test plan amendment safety guardrails
- Test context budget management (truncation)
- Test git rollback with complex file states (new files, modified files, deleted files)
- Test error recovery (CLI failure, invalid JSON output, timeout)
- Create test fixtures in `tests/fixtures/`

**Acceptance criteria**: All bats tests pass. Test coverage covers every module function. Edge cases for git operations, JSON parsing, and compaction triggers are covered. Tests run in under 30 seconds.

**Skills**: `["testing-bats", "bash-conventions"]`

**Max turns**: 25

---

### Phase 12: Documentation and self-bootstrapping verification

**Scope**: Final documentation, README, and end-to-end verification.

**Tasks**:
- Write README.md with setup instructions, usage, and configuration reference
- Write CLAUDE.md with project conventions for future development
- Run the complete test suite
- Run shellcheck on all bash files
- Verify the orchestrator can run its first real iteration (self-test)
- Create an example `plan.json` for a sample project

**Acceptance criteria**: README is complete and accurate. All tests pass. Shellcheck passes on all `.sh` files. A real `claude -p` invocation succeeds with the orchestrator's configuration. The system is self-bootstrapping: the plan.json in this repo can be used to re-implement the system.

**Skills**: `[]`

**Max turns**: 15

---

## 4. LLM-implementability assessment (DD-22-01)

Scoring uses the DD-22-01 framework with six dimensions, each scored 0–3. **Compass weighting applies 1.5× multiplier to LI-1 (Documentation Quality) and LI-3 (Code Complexity)**. Maximum weighted score is **21.0**. Threshold for concern: weighted total below **12.0** or any single dimension at **0**.

### Bash scripting (the orchestrator)

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| LI-1: Documentation Quality | **3** × 1.5 = 4.5 | Bash is exhaustively documented (man pages, TLDP, countless tutorials). LLMs have massive training data on bash scripting patterns. |
| LI-2: MCP Tool Availability | **2** | No MCP server needed — Claude Code has native Bash tool. Excellent integration through built-in tool execution. |
| LI-3: Code Complexity | **2** × 1.5 = 3.0 | Moderate — the orchestrator involves process management, signal handling, and JSON manipulation. Sequential logic but many interacting state variables. |
| LI-4: Testability | **3** | bats-core provides excellent test infrastructure. Functions can be tested in isolation. Exit codes give clear pass/fail. |
| LI-5: LLM Familiarity | **3** | Bash is ubiquitous in training data. Claude generates correct bash with very high reliability. |
| LI-6: Hallucination Risk | **2** | Stable conventions, but subtle gotchas exist (quoting, `set -e` behavior, word splitting). LLMs occasionally produce bash with quoting errors. |
| **Weighted Total** | **17.5/21** | **HIGH implementability** |

### jq (JSON processing)

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| LI-1: Documentation Quality | **3** × 1.5 = 4.5 | jq has excellent official manual, playground, and widespread tutorial coverage. |
| LI-2: MCP Tool Availability | **1** | No MCP server. Used via bash command execution. |
| LI-3: Code Complexity | **2** × 1.5 = 3.0 | jq expressions for array manipulation and conditional updates are moderately complex. Nested filters can be tricky. |
| LI-4: Testability | **2** | Can test jq expressions directly in bash. Input/output is deterministic JSON. |
| LI-5: LLM Familiarity | **3** | Very common in training data (DevOps, CI/CD scripts, Stack Overflow). |
| LI-6: Hallucination Risk | **1** | jq syntax is idiosyncratic and LLMs frequently hallucinate incorrect filter expressions, especially for complex array operations. **This is a known risk.** |
| **Weighted Total** | **14.5/21** | **MODERATE-HIGH — jq hallucination is the primary risk** |

**Mitigation**: Provide extensive jq examples in skill files. Test every jq expression in isolation. Use simple, composable filters rather than complex one-liners.

### Claude Code CLI

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| LI-1: Documentation Quality | **2** × 1.5 = 3.0 | Official docs have known gaps (GitHub issues track missing CLI flags). `--help` output contains flags not in docs. Cross-referencing needed. |
| LI-2: MCP Tool Availability | **3** | Claude Code IS the MCP tool — native integration. |
| LI-3: Code Complexity | **3** × 1.5 = 4.5 | CLI invocation is straightforward command-line usage. Flag syntax is standard. |
| LI-4: Testability | **2** | Can test with dry-run, mock the CLI for unit tests. Real integration tests require active subscription. |
| LI-5: LLM Familiarity | **2** | Moderate — Claude Code CLI is relatively new (2025). Less training data than mature tools, but the implementing agent IS Claude Code. |
| LI-6: Hallucination Risk | **1** | Flags have changed across versions. `--json-schema` behavior specifics, `--strict-mcp-config` edge cases, and output format details are commonly hallucinated. **High risk.** |
| **Weighted Total** | **14.5/21** | **MODERATE-HIGH — flag hallucination is the second-highest risk** |

**Mitigation**: The implementation plan includes exact, verified flag syntax for every CLI invocation. Each Phase 8 function includes literal CLI command strings. Integration tests verify real CLI behavior.

### Context7 MCP Server (@upstash/context7-mcp)

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| LI-1: Documentation Quality | **2** × 1.5 = 3.0 | Good README, but tool signatures require checking. Two tools with clear parameters. |
| LI-2: MCP Tool Availability | **3** | This IS an MCP server. Two tools: `resolve-library-id` and `get-library-docs`. |
| LI-3: Code Complexity | **3** × 1.5 = 4.5 | Zero code to write — just configuration. MCP config JSON is declarative. |
| LI-4: Testability | **2** | Can verify MCP connection and tool availability. Query results are non-deterministic but verifiable. |
| LI-5: LLM Familiarity | **2** | Moderately represented in training data. Ranked #3 on PulseMCP. |
| LI-6: Hallucination Risk | **1** | Tool names and parameters may be hallucinated. The `resolve-library-id` → `get-library-docs` two-step flow is a specific pattern LLMs might skip. |
| **Weighted Total** | **15.5/21** | **HIGH implementability** |

### Knowledge Graph Memory Server (@modelcontextprotocol/server-memory)

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| LI-1: Documentation Quality | **2** × 1.5 = 3.0 | Official Anthropic reference server. Good README with 9 documented tools. |
| LI-2: MCP Tool Availability | **3** | This IS an MCP server. 9 tools with clear CRUD semantics. |
| LI-3: Code Complexity | **3** × 1.5 = 4.5 | Configuration only. Entity/relation model is simple and well-documented. |
| LI-4: Testability | **2** | Can verify entities are created/retrieved. JSONL storage is inspectable. |
| LI-5: LLM Familiarity | **2** | Official Anthropic server, well-represented in MCP documentation and tutorials. |
| LI-6: Hallucination Risk | **2** | Stable API with clear tool names. Entity model is simple enough that hallucination is unlikely. |
| **Weighted Total** | **16.5/21** | **HIGH implementability** |

### bats-core (test framework)

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| LI-1: Documentation Quality | **3** × 1.5 = 4.5 | Excellent ReadTheDocs documentation. 5,700 GitHub stars. Extensive tutorials and examples online. |
| LI-2: MCP Tool Availability | **1** | No MCP server. Invoked via bash command. |
| LI-3: Code Complexity | **3** × 1.5 = 4.5 | `@test` syntax is extremely simple. `run` + `$status` + `$output` pattern is intuitive. |
| LI-4: Testability | **3** | This IS the test framework. Meta-tests can verify the framework works. TAP output is machine-readable. |
| LI-5: LLM Familiarity | **3** | Most popular bash testing framework. Heavily represented in training data. |
| LI-6: Hallucination Risk | **2** | Stable syntax, but `bats-assert` helper functions (`assert_success`, `assert_output`) are sometimes confused with built-in syntax. |
| **Weighted Total** | **18.0/21** | **VERY HIGH implementability** |

### Git (rollback mechanism)

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| LI-1: Documentation Quality | **3** × 1.5 = 4.5 | Git has the most comprehensive documentation of any version control system. |
| LI-2: MCP Tool Availability | **2** | No MCP server needed. Claude Code has native git integration via Bash tool. |
| LI-3: Code Complexity | **3** × 1.5 = 4.5 | `git reset --hard`, `git clean -fd`, `git rev-parse HEAD` are simple, well-known commands. |
| LI-4: Testability | **3** | Git operations are fully deterministic and verifiable. Tests can create temp repos. |
| LI-5: LLM Familiarity | **3** | Git is arguably the most-represented tool in LLM training data. |
| LI-6: Hallucination Risk | **2** | Core commands are very stable. Edge cases around `clean -fd` vs `-fdx` and untracked file handling occasionally trip up LLMs. |
| **Weighted Total** | **19.0/21** | **VERY HIGH implementability** |

### Summary heatmap

| Technology | Weighted Score | Risk Level | Primary Risk |
|------------|---------------|------------|--------------|
| Git | **19.0** | 🟢 Very Low | None significant |
| bats-core | **18.0** | 🟢 Very Low | Minor bats-assert confusion |
| Bash scripting | **17.5** | 🟢 Low | Quoting edge cases |
| KG Memory Server | **16.5** | 🟢 Low | None significant |
| Context7 MCP | **15.5** | 🟡 Low-Moderate | Tool name hallucination |
| jq | **14.5** | 🟡 Moderate | Complex filter hallucination |
| Claude Code CLI | **14.5** | 🟡 Moderate | Flag syntax hallucination |

**All technologies score above the 12.0 concern threshold.** The two moderate-risk areas (jq and CLI flags) are mitigated by providing exact, verified syntax in skill files and templates.

---

## 5. Complexity profile

| Metric | Value | Notes |
|--------|-------|-------|
| **Concept count** | **14** | Bash loop, CLI invocation, MCP configs, JSON schemas, handoff documents, compaction levels, context assembly, validation gates, git rollback, plan mutation, skills injection, state management, token budgeting, prompt templates |
| **Integration points** | **6** | Claude Code CLI, Context7 MCP, KG Memory MCP, git, jq, bats-core |
| **Pattern conventionality** | **High** | Serial bash loop, JSON config, git workflow — all standard patterns. Only the compaction strategy is novel. |
| **Test coverage feasibility** | **High** | Every module function is independently testable. Integration tests use mocked CLI. bats-core is well-suited. Target: **>85% function coverage**. |
| **Expected iteration cycles** | **12 phases × 1.5 avg attempts = ~18 iterations** | Some phases will pass on first try; Phase 8 (CLI integration) and Phase 9 (wiring) may need 2-3 attempts each. |
| **Token budget estimate** | ~**8,000-12,000 tokens per coding prompt** | Task description (500-1,000) + compacted context (2,000-4,000) + previous handoff L2 (500-1,500) + skills (1,000-2,000) + output instructions (500) |
| **Total orchestrator code** | **~350-450 lines** | `ralph.sh` (~120 lines) + 5 library modules (~50-70 lines each) |
| **Estimated calendar time** | **6-10 hours of Claude Code time** | 18 iterations × 5-15 min each, plus compaction iterations |

---

## 6. Risk assessment

### Highest-risk components for LLM implementation

**Risk 1: jq complex filter expressions (MODERATE)**. The plan mutation logic requires array slicing, conditional updates, and nested object manipulation in jq. LLMs hallucinate jq syntax at a noticeably higher rate than other shell constructs. **Mitigation**: The `jq-patterns.md` skill file contains every jq pattern needed, pre-verified. Each plan-ops function uses a single, tested jq expression. Phase 4 tests verify every jq operation individually.

**Risk 2: Claude Code CLI flag interactions (MODERATE)**. Combining `--json-schema` with `--output-format json` and `--strict-mcp-config` in a single invocation has specific ordering and interaction requirements that are incompletely documented. **Mitigation**: Phase 8 provides literal, verified command strings. Integration tests in Phase 11 verify real CLI behavior. The `mcp-config.md` skill file documents exact flag combinations.

**Risk 3: Structured output parsing reliability (LOW-MODERATE)**. The `--json-schema` flag uses constrained decoding, but the agent may fail to produce valid output after retries (error subtype `error_max_structured_output_retries`). If Claude refuses for safety reasons, output may not match the schema. **Mitigation**: The orchestrator includes fallback parsing that extracts key fields from free-text output if structured parsing fails. Handoff schema uses only simple types (strings, arrays of strings, booleans) to maximize schema compliance.

**Risk 4: Rate limiting on Max subscription (LOW-MODERATE)**. Claude Max $200/month has a shared rate limit across web and CLI usage, with 5-hour rolling windows. An aggressive orchestration run could exhaust the limit. **Mitigation**: The orchestrator logs `duration_ms` and `num_turns` from each response and tracks cumulative usage. A configurable `min_delay_between_iterations` (default: 30 seconds) prevents rapid-fire requests. The `--max-turns` flag caps each iteration.

**Risk 5: MCP server startup latency (LOW)**. Context7 and KG Memory Server start via `npx`, which involves downloading and launching Node.js processes. First-run latency can be 10-30 seconds. **Mitigation**: Memory iterations are infrequent (every ~5 coding iterations). The MCP servers are pre-installed (`npm install -g`) rather than relying on `npx -y` each time.

### What needs the most detailed specification

The **handoff JSON schema** and **CLI invocation strings** need the most precise specification because they sit at the boundary between the orchestrator and Claude Code. Any ambiguity in the schema causes parse failures; any incorrect flag causes CLI errors. Both are fully specified in this document.

### Where hallucination risk is highest

**jq filter expressions** and **CLI flag combinations** are the two areas where Claude Code is most likely to hallucinate plausible-but-wrong syntax. The plan addresses this by providing exact, verified expressions in skill files rather than relying on the agent to synthesize them from memory.

---

## 7. The handoff schema

### Full JSON Schema (`handoff-schema.json`)

```json
{
  "type": "object",
  "properties": {
    "task_completed": {
      "type": "object",
      "properties": {
        "task_id": { "type": "string" },
        "summary": { "type": "string" },
        "fully_complete": { "type": "boolean" }
      },
      "required": ["task_id", "summary", "fully_complete"]
    },
    "deviations": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "planned": { "type": "string" },
          "actual": { "type": "string" },
          "reason": { "type": "string" }
        },
        "required": ["planned", "actual", "reason"]
      }
    },
    "bugs_encountered": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "description": { "type": "string" },
          "resolution": { "type": "string" },
          "resolved": { "type": "boolean" }
        },
        "required": ["description", "resolution", "resolved"]
      }
    },
    "architectural_notes": {
      "type": "array",
      "items": { "type": "string" }
    },
    "unfinished_business": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "item": { "type": "string" },
          "reason": { "type": "string" },
          "priority": { "type": "string", "enum": ["high", "medium", "low"] }
        },
        "required": ["item", "reason", "priority"]
      }
    },
    "recommendations": {
      "type": "array",
      "items": { "type": "string" }
    },
    "files_touched": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "path": { "type": "string" },
          "action": { "type": "string", "enum": ["created", "modified", "deleted"] }
        },
        "required": ["path", "action"]
      }
    },
    "plan_amendments": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "action": { "type": "string", "enum": ["add", "modify", "remove"] },
          "task_id": { "type": "string" },
          "task": {
            "type": "object",
            "properties": {
              "id": { "type": "string" },
              "title": { "type": "string" },
              "description": { "type": "string" },
              "skills": { "type": "array", "items": { "type": "string" } },
              "needs_docs": { "type": "boolean" },
              "libraries": { "type": "array", "items": { "type": "string" } },
              "acceptance_criteria": { "type": "array", "items": { "type": "string" } },
              "depends_on": { "type": "array", "items": { "type": "string" } }
            }
          },
          "changes": { "type": "object" },
          "after": { "type": "string" },
          "reason": { "type": "string" }
        },
        "required": ["action", "reason"]
      }
    },
    "tests_added": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "file": { "type": "string" },
          "test_names": { "type": "array", "items": { "type": "string" } }
        },
        "required": ["file", "test_names"]
      }
    },
    "constraints_discovered": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "constraint": { "type": "string" },
          "impact": { "type": "string" },
          "workaround": { "type": "string" }
        },
        "required": ["constraint", "impact"]
      }
    }
  },
  "required": [
    "task_completed",
    "deviations",
    "bugs_encountered",
    "architectural_notes",
    "files_touched",
    "plan_amendments",
    "tests_added",
    "constraints_discovered"
  ]
}
```

### Example handoff output

```json
{
  "task_completed": {
    "task_id": "TASK-003",
    "summary": "Implemented git-ops.sh with checkpoint, rollback, and commit functions. All three bats tests pass.",
    "fully_complete": true
  },
  "deviations": [
    {
      "planned": "Use git tags for checkpoints",
      "actual": "Used git rev-parse HEAD to capture commit hashes directly",
      "reason": "Simpler and avoids tag namespace pollution"
    }
  ],
  "bugs_encountered": [
    {
      "description": "git clean -fd was removing .ralph/state.json",
      "resolution": "Added .ralph/ to .gitignore exception list before clean",
      "resolved": true
    }
  ],
  "architectural_notes": [
    "Decided to always auto-commit before iteration starts, creating clean reset points",
    "git clean -fd is essential — reset --hard alone doesn't remove new untracked files"
  ],
  "unfinished_business": [],
  "recommendations": [
    "Consider adding a --dry-run flag to git-ops functions for testing"
  ],
  "files_touched": [
    { "path": ".ralph/lib/git-ops.sh", "action": "created" },
    { "path": "tests/git-ops.bats", "action": "created" },
    { "path": ".gitignore", "action": "modified" }
  ],
  "plan_amendments": [],
  "tests_added": [
    {
      "file": "tests/git-ops.bats",
      "test_names": [
        "create_checkpoint captures current HEAD",
        "rollback_to_checkpoint restores previous state",
        "rollback removes untracked files"
      ]
    }
  ],
  "constraints_discovered": [
    {
      "constraint": "git clean -fd removes files matching .gitignore patterns",
      "impact": "Runtime state files must be explicitly excluded from clean",
      "workaround": "Use git clean -fd --exclude=.ralph/"
    }
  ]
}
```

---

## 8. The compaction strategy

### Three levels of handoff compression

**L1 — One-line summary** (~20-50 tokens per iteration):
Extracted by the orchestrator via `jq`: `"[TASK-003] Implemented git-ops.sh. Complete. 3 files touched."`

```bash
extract_l1() {
    local handoff_file="$1"
    jq -r '"[\(.task_completed.task_id)] \(.task_completed.summary | split(". ")[0]). \(if .task_completed.fully_complete then "Complete" else "Partial" end). \(.files_touched | length) files."' "$handoff_file"
}
```

**L2 — Key decisions, constraints, failed approaches** (~200-500 tokens per iteration):
Extracted by the orchestrator via `jq`, combining architectural notes, deviations, constraints, and bugs:

```bash
extract_l2() {
    local handoff_file="$1"
    jq -r '{
        task: .task_completed.task_id,
        decisions: .architectural_notes,
        deviations: [.deviations[] | "\(.planned) → \(.actual): \(.reason)"],
        constraints: [.constraints_discovered[] | "\(.constraint): \(.workaround // .impact)"],
        failed: [.bugs_encountered[] | select(.resolved == false) | .description],
        unfinished: [.unfinished_business[] | "\(.item) (\(.priority))"]
    }' "$handoff_file"
}
```

**L3 — Full handoff document** (~500-2,000 tokens per iteration):
The complete handoff JSON as written by the coding agent. Stored in `handoffs/handoff-NNN.json`.

### How the orchestrator decides which level to inject

The decision depends on available context budget and iteration distance:

**For regular coding iterations** (no compaction triggered):
- **Last iteration**: Inject L2 (~200-500 tokens)
- **Iterations 2-3 back**: Inject L1 (~20-50 tokens each)
- **Older iterations**: Not injected (available via compacted context)

**After a compaction iteration**:
The memory agent produces a structured compacted context that replaces all individual L1/L2 entries. This compacted context includes:
- A rolling summary of all work completed so far
- Active constraints and architectural decisions (deduplicated)
- Unresolved bugs and unfinished business
- Key file-level knowledge (what files exist, their purpose)

### Token budget allocation across levels

| Context Section | Token Budget | Source |
|----------------|-------------|--------|
| Task description + acceptance criteria | 1,000 | plan.json (via jq) |
| Skills injection | 1,500 | skills/*.md files |
| Compacted context (from memory agent) | 3,000 | context/compacted-latest.json |
| Previous iteration L2 | 500 | handoffs/ (via jq) |
| Earlier iterations L1 (last 3) | 150 | handoffs/ (via jq) |
| Output instructions + schema reference | 500 | templates/ |
| **Total input budget** | **~6,650** | |
| **Reserved for agent work + response** | **~140,000** | Claude Code's working context |

### Memory agent output schema (`memory-output-schema.json`)

```json
{
  "type": "object",
  "properties": {
    "project_summary": { "type": "string" },
    "completed_work": {
      "type": "array",
      "items": { "type": "string" }
    },
    "active_constraints": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "constraint": { "type": "string" },
          "source_iteration": { "type": "string" }
        },
        "required": ["constraint"]
      }
    },
    "architectural_decisions": {
      "type": "array",
      "items": { "type": "string" }
    },
    "unresolved_issues": {
      "type": "array",
      "items": { "type": "string" }
    },
    "file_knowledge": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "path": { "type": "string" },
          "purpose": { "type": "string" }
        },
        "required": ["path", "purpose"]
      }
    },
    "library_docs": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "library": { "type": "string" },
          "key_apis": { "type": "string" },
          "usage_notes": { "type": "string" }
        },
        "required": ["library", "key_apis"]
      }
    }
  },
  "required": [
    "project_summary",
    "completed_work",
    "active_constraints",
    "architectural_decisions",
    "file_knowledge"
  ]
}
```

---

## 9. Context budget management

### What goes into each coding iteration's prompt

The prompt is assembled by `build_coding_prompt()` in priority order. If the total exceeds **8,000 tokens** (estimated via character count ÷ 4), sections are truncated starting from the lowest priority:

| Priority | Section | Budget | Content |
|----------|---------|--------|---------|
| 1 (highest) | Task description | 1,000 | ID, title, description, acceptance criteria from plan.json |
| 2 | Output instructions | 500 | "Produce handoff JSON matching the schema. Run acceptance checks before finalizing." |
| 3 | Skills | 1,500 | Concatenated skill files matching task's `skills` array |
| 4 | Previous iteration L2 | 500 | Key decisions, constraints, bugs from the immediately preceding iteration |
| 5 | Compacted context | 3,000 | Memory agent's structured output (project summary, constraints, file knowledge) |
| 6 (lowest) | Earlier L1 summaries | 150 | One-line summaries of 2-3 preceding iterations |

### How context is prioritized when budget is tight

The truncation algorithm works bottom-up: L1 summaries are dropped first, then compacted context is trimmed (keeping `project_summary` and `active_constraints`, dropping `file_knowledge` and `library_docs`), then skills are reduced to the first skill file only. Task description and output instructions are never truncated.

```bash
truncate_to_budget() {
    local content="$1"
    local max_chars=$((8000 * 4))  # ~8000 tokens × 4 chars/token
    
    local current_chars=${#content}
    if [ "$current_chars" -le "$max_chars" ]; then
        echo "$content"
        return
    fi
    
    # Truncate from the end, preserving the priority-ordered beginning
    echo "${content:0:$max_chars}"
    echo ""
    echo "[CONTEXT TRUNCATED — ${current_chars} chars exceeded ${max_chars} char budget]"
}
```

### How the memory agent's structured output maps to prompt sections

The memory agent outputs JSON matching `memory-output-schema.json`. The orchestrator transforms this into markdown sections for the coding prompt:

```bash
format_compacted_context() {
    local compacted_file="$1"
    
    echo "### Project State"
    jq -r '.project_summary' "$compacted_file"
    echo ""
    
    echo "### Completed Work"
    jq -r '.completed_work[] | "- " + .' "$compacted_file"
    echo ""
    
    echo "### Active Constraints (DO NOT VIOLATE)"
    jq -r '.active_constraints[] | "- " + .constraint' "$compacted_file"
    echo ""
    
    echo "### Architecture Decisions (Follow These)"
    jq -r '.architectural_decisions[] | "- " + .' "$compacted_file"
    echo ""
    
    if jq -e '.library_docs | length > 0' "$compacted_file" >/dev/null 2>&1; then
        echo "### Library Reference"
        jq -r '.library_docs[] | "**\(.library)**: \(.key_apis)\n\(.usage_notes // "")\n"' "$compacted_file"
    fi
}
```

---

## 10. Configuration and customization

### `ralph.conf` — environment and project settings

```bash
# .ralph/config/ralph.conf

# === Core Settings ===
RALPH_MAX_ITERATIONS=50
RALPH_PLAN_FILE="plan.json"
RALPH_VALIDATION_STRATEGY="strict"  # strict | lenient | tests_only

# === Compaction Settings ===
RALPH_COMPACTION_INTERVAL=5          # Coding iterations between compactions
RALPH_COMPACTION_THRESHOLD_BYTES=32000  # ~8000 tokens
RALPH_COMPACTION_MAX_TURNS=10

# === Coding Iteration Settings ===
RALPH_DEFAULT_MAX_TURNS=20
RALPH_MIN_DELAY_SECONDS=30           # Rate limit protection
RALPH_CONTEXT_BUDGET_TOKENS=8000

# === CLI Settings ===
RALPH_MODEL=""                        # Empty = default model
RALPH_FALLBACK_MODEL="sonnet"
RALPH_SKIP_PERMISSIONS=true

# === Git Settings ===
RALPH_AUTO_COMMIT=true
RALPH_COMMIT_PREFIX="ralph"

# === Logging ===
RALPH_LOG_LEVEL="info"                # debug | info | warn | error
RALPH_LOG_FILE=".ralph/logs/ralph.log"

# === Validation Commands (project-specific) ===
RALPH_VALIDATION_COMMANDS=(
    "bats tests/"
    "shellcheck .ralph/ralph.sh .ralph/lib/*.sh"
)
```

### How the system adapts to different project types

The orchestrator is project-agnostic by design. Project-specific behavior is controlled through three extension points:

1. **Validation commands** in `ralph.conf`: Override `RALPH_VALIDATION_COMMANDS` with project-appropriate checks (e.g., `npm test`, `pytest`, `cargo test`)
2. **Skills files**: Add project-specific skill files to `.ralph/skills/` and reference them in task metadata
3. **Plan structure**: The `plan.json` format is generic — task descriptions, acceptance criteria, and dependencies work for any project type

### Per-project MCP configuration

For projects needing additional MCP servers (e.g., a database server for integration tests), add them to `mcp-coding.json`:

```json
{
  "mcpServers": {
    "project-db": {
      "command": "npx",
      "args": ["-y", "@mcp/postgres-server"],
      "env": { "DATABASE_URL": "${DATABASE_URL}" }
    }
  }
}
```

The `mcp-memory.json` file can also be extended with project-specific documentation sources. For instance, adding a local docs MCP using mcpdoc:

```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp@latest"]
    },
    "memory": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-memory"],
      "env": { "MEMORY_FILE_PATH": ".ralph/memory.jsonl" }
    },
    "project-docs": {
      "command": "npx",
      "args": ["-y", "@chr33s/mcpdoc", "--urls", "ProjectDocs:./docs/llms.txt", "--transport", "stdio"]
    }
  }
}
```

---

## Conclusion: a deliberately boring system that works

This plan specifies a system with **14 concepts, 6 integration points, and ~400 lines of bash** — intentionally kept at the edge of simplicity. Every technology scores above the DD-22-01 concern threshold, with the two moderate risks (jq hallucination and CLI flag accuracy) addressed by providing pre-verified syntax in skill files rather than trusting the implementing agent to generate them from memory.

The 12-phase implementation sequence is ordered so that **each phase produces testable output** and later phases compose earlier modules without modification. The estimated **18 total iterations** (including retries) should complete within a single day's Claude Max rate limit budget, with the 30-second inter-iteration delay providing natural rate limit protection.

Three design choices distinguish this from stock Ralph: the **three-tier compaction strategy** replaces Ralph's flat `progress.txt` with structured L1/L2/L3 hierarchical compression; **MCP isolation via `--strict-mcp-config`** gives coding and memory iterations different toolkits; and **plan mutation with safety guardrails** lets the agent adapt its own task list while the orchestrator maintains control. The system is self-bootstrapping — the `plan.json` produced by Phase 1 encodes the remaining 11 phases, meaning Claude Code can build the orchestrator by following the orchestrator's own plan format.