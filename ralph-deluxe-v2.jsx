import { useState, useEffect, useCallback } from "react";

// --- Data Models (would come from polling JSON files in production) ---
const MOCK_STATE = {
  mode: "handoff-only", // "handoff-only" | "handoff-plus-index"
  status: "running", // "idle" | "running" | "paused" | "completed" | "failed"
  current_iteration: 7,
  current_task: "TASK-005",
  iteration_type: "coding", // "coding" | "compaction"
  started_at: "2026-02-06T14:30:00Z",
  elapsed_minutes: 23,
  coding_iterations: 6,
  compaction_iterations: 1,
  validation_strategy: "strict",
};

const MOCK_PLAN = [
  { id: "TASK-001", title: "Project scaffold", status: "done", order: 1 },
  { id: "TASK-002", title: "Core loop skeleton", status: "done", order: 2 },
  { id: "TASK-003", title: "Git operations module", status: "done", order: 3 },
  { id: "TASK-004", title: "Plan operations module", status: "done", order: 4 },
  { id: "TASK-005", title: "Context assembly", status: "in_progress", order: 5 },
  { id: "TASK-006", title: "Validation gates", status: "pending", order: 6 },
  { id: "TASK-007", title: "Handoff parsing", status: "pending", order: 7 },
  { id: "TASK-008", title: "CLI integration", status: "pending", order: 8 },
  { id: "TASK-009", title: "Wire everything", status: "pending", order: 9 },
  { id: "TASK-010", title: "Templates & skills", status: "pending", order: 10 },
];

const MOCK_HANDOFFS = [
  {
    iteration: 1,
    task_id: "TASK-001",
    timestamp: "2026-02-06T14:32:00Z",
    summary: "Created directory structure, all config files, JSON schemas. All directories exist, all JSON valid.",
    fully_complete: true,
    deviations: [],
    constraints: [],
    architectural_notes: ["Chose .ralph/ prefix for all orchestrator files to avoid conflicts"],
    freeform: "Clean scaffold. No surprises. The handoff-schema.json validates correctly with jq. Ready for the loop skeleton.",
    files_touched: 14,
    validation_passed: true,
  },
  {
    iteration: 2,
    task_id: "TASK-002",
    timestamp: "2026-02-06T14:36:00Z",
    summary: "Main loop with argument parsing, signal handling, stub functions. Dry-run mode works.",
    fully_complete: true,
    deviations: [{ planned: "Single ralph.sh file", actual: "Split into ralph.sh + lib/ modules", reason: "Better testability" }],
    constraints: [{ constraint: "bash 4.0+ required for associative arrays", impact: "macOS ships bash 3.2" }],
    architectural_notes: ["Source lib/ modules via relative path from script location", "trap SIGINT/SIGTERM for graceful shutdown"],
    freeform: "The main loop reads cleanly. State machine: idle → running → [paused] → completed/failed. Each iteration is checkpoint → work → validate → commit/rollback. The dry-run flag skips claude invocation and git operations but exercises all the routing logic.\n\nWatch out: macOS default bash is 3.2 which lacks associative arrays. Either require bash 4+ or avoid them entirely. I chose to require 4+ since we control the environment.",
    files_touched: 7,
    validation_passed: true,
  },
  {
    iteration: 3,
    task_id: "TASK-003",
    timestamp: "2026-02-06T14:41:00Z",
    summary: "Git checkpoint/rollback/commit implemented. 3 bats tests pass.",
    fully_complete: true,
    deviations: [{ planned: "git tags for checkpoints", actual: "git rev-parse HEAD for commit hashes", reason: "Simpler, no tag namespace pollution" }],
    constraints: [{ constraint: "git clean -fd removes files matching .gitignore", impact: "Runtime state files need exclusion" }],
    architectural_notes: ["Always auto-commit before iteration starts", "git clean -fd essential — reset --hard alone doesn't remove new untracked files"],
    freeform: "Key learning: git clean -fd with --exclude=.ralph/ is the safe pattern. Without the exclude, it nukes state.json on rollback. Found this the hard way when test 2 failed initially.\n\nThe checkpoint → rollback cycle is bulletproof now. Test creates files, checkpoints, makes changes, rolls back, verifies originals restored AND new files cleaned up.",
    files_touched: 3,
    validation_passed: true,
  },
  {
    iteration: 4,
    task_id: "TASK-003",
    timestamp: "2026-02-06T14:46:00Z",
    summary: "Fixed edge case in rollback when .ralph/ directory doesn't exist yet.",
    fully_complete: true,
    deviations: [],
    constraints: [],
    architectural_notes: ["Added ensure_ralph_dir() guard before git clean"],
    freeform: "Minor fix. The rollback function assumed .ralph/ existed for the --exclude flag. On first-ever iteration with no prior commits, git clean would fail. Added a mkdir -p guard. All 4 tests pass now.",
    files_touched: 2,
    validation_passed: true,
  },
  {
    iteration: 5,
    task_id: "TASK-004",
    timestamp: "2026-02-06T14:52:00Z",
    summary: "Plan operations: get_next_task, set_task_status, apply_amendments with safety guardrails.",
    fully_complete: true,
    deviations: [],
    constraints: [{ constraint: "jq --argjson needed for numeric values, not --arg", impact: "Causes silent failures if wrong" }],
    architectural_notes: ["Amendment safety: max 3 per iteration, no removing done tasks, backup before mutation", "Dependency resolution: topological sort via depends_on array"],
    freeform: "The jq expressions for plan mutation are the trickiest part so far. Key gotcha: --arg passes strings, --argjson passes raw JSON values. Using --arg for a number silently wraps it in quotes, breaking numeric comparisons downstream.\n\nAmendment apply uses: jq 'map(if .id == $id then . + $changes else . end)' for modifications. Array slicing for insertions. del() for removals. Each pattern is individually tested.\n\nThe dependency resolver is simple: for each pending task, check if all depends_on IDs have status 'done'. First match wins. No cycle detection — we trust the plan author.",
    files_touched: 4,
    validation_passed: true,
  },
  {
    iteration: 6,
    task_id: "TASK-005",
    timestamp: "2026-02-06T14:58:00Z",
    summary: "Context assembly partially complete. Prompt building works, skill loading works. Token estimation untested.",
    fully_complete: false,
    deviations: [{ planned: "Character count ÷ 4 for tokens", actual: "Still using char count, need to validate ratio", reason: "Haven't found reliable test data yet" }],
    constraints: [],
    architectural_notes: ["Priority order: task > acceptance criteria > skills > handoff > compacted context", "Truncation is bottom-up: drop lowest priority first"],
    freeform: "The prompt assembly pipeline is: task JSON → acceptance criteria → skills files → previous handoff → compacted context (if in handoff+index mode). Each section has a token budget.\n\nThe skill loader reads task.skills array and concatenates matching .ralph/skills/*.md files. Simple and works.\n\nTODO: The token estimation (chars ÷ 4) needs validation. For code-heavy content the ratio might be closer to 3.5. For natural language closer to 4.5. Not critical for v1 but worth measuring.\n\nThe truncation logic is clean: iterate sections from lowest priority, remove or trim until under budget. Task description and output instructions are never truncated.",
    files_touched: 3,
    validation_passed: true,
  },
  {
    iteration: 7,
    task_id: "TASK-005",
    timestamp: "2026-02-06T15:03:00Z",
    summary: "Continuing context assembly. Adding handoff injection for both modes.",
    fully_complete: false,
    deviations: [],
    constraints: [],
    architectural_notes: [],
    freeform: "Working on the mode-dependent context injection. In handoff-only mode: just pass the previous handoff verbatim. In handoff+index mode: pass the previous handoff plus the knowledge index header.\n\nThe index header is a lightweight table: iteration | task | one-line summary | tags. The coding agent can then grep specific handoff files if it needs details. This keeps the injected context small while making everything discoverable.",
    files_touched: 2,
    validation_passed: null, // still running
  },
];

const MOCK_INDEX = [
  { iteration: 1, task: "TASK-001", summary: "Project scaffold created", tags: ["setup", "config", "schema"] },
  { iteration: 2, task: "TASK-002", summary: "Main loop skeleton with dry-run", tags: ["loop", "cli", "signals"] },
  { iteration: 3, task: "TASK-003", summary: "Git ops — checkpoint/rollback pattern", tags: ["git", "rollback", "clean"] },
  { iteration: 4, task: "TASK-003", summary: "Git ops edge case fix", tags: ["git", "bugfix"] },
  { iteration: 5, task: "TASK-004", summary: "Plan ops — jq mutations + amendments", tags: ["jq", "plan", "amendments", "dependencies"] },
  { iteration: 6, task: "TASK-005", summary: "Context assembly — prompt building + skills", tags: ["context", "skills", "tokens"] },
];

const MOCK_METRICS = {
  total_iterations: 7,
  successful_validations: 6,
  failed_validations: 0,
  rollbacks: 0,
  avg_duration_seconds: 185,
  total_files_touched: 35,
  compaction_runs: 1,
  tasks_completed: 4,
  tasks_remaining: 6,
};

// --- Components ---

const StatusBadge = ({ status }) => {
  const colors = {
    done: "bg-emerald-900/60 text-emerald-300 border-emerald-700/50",
    in_progress: "bg-amber-900/60 text-amber-300 border-amber-700/50",
    pending: "bg-zinc-800/60 text-zinc-400 border-zinc-700/50",
    failed: "bg-red-900/60 text-red-300 border-red-700/50",
    skipped: "bg-zinc-800/40 text-zinc-500 border-zinc-700/30",
    running: "bg-blue-900/60 text-blue-300 border-blue-600/50",
    idle: "bg-zinc-800/60 text-zinc-400 border-zinc-700/50",
    paused: "bg-orange-900/60 text-orange-300 border-orange-700/50",
    completed: "bg-emerald-900/60 text-emerald-300 border-emerald-700/50",
  };
  return (
    <span className={`px-2 py-0.5 rounded text-xs font-mono border ${colors[status] || colors.pending}`}>
      {status}
    </span>
  );
};

const ModeToggle = ({ mode, onToggle }) => (
  <div className="flex items-center gap-3 p-3 rounded-lg bg-zinc-900/80 border border-zinc-800">
    <span className="text-xs text-zinc-500 uppercase tracking-wider font-semibold">Mode</span>
    <button
      onClick={onToggle}
      className="relative flex items-center h-7 rounded-full transition-colors"
      style={{ width: "220px", background: mode === "handoff-only" ? "#1e293b" : "#1e1b2e" }}
    >
      <div
        className="absolute h-6 rounded-full transition-all duration-300 ease-out"
        style={{
          width: mode === "handoff-only" ? "105px" : "125px",
          left: mode === "handoff-only" ? "2px" : "93px",
          background: mode === "handoff-only" ? "#2563eb" : "#7c3aed",
        }}
      />
      <span className={`relative z-10 text-xs font-medium px-3 transition-colors ${mode === "handoff-only" ? "text-white" : "text-zinc-500"}`}>
        Handoff Only
      </span>
      <span className={`relative z-10 text-xs font-medium px-3 transition-colors ${mode === "handoff-plus-index" ? "text-white" : "text-zinc-500"}`}>
        + Knowledge Index
      </span>
    </button>
  </div>
);

const MetricsStrip = ({ metrics, state }) => (
  <div className="grid grid-cols-2 sm:grid-cols-4 lg:grid-cols-8 gap-2">
    {[
      { label: "Iteration", value: state.current_iteration, accent: "text-blue-400" },
      { label: "Tasks Done", value: `${metrics.tasks_completed}/${metrics.tasks_completed + metrics.tasks_remaining}`, accent: "text-emerald-400" },
      { label: "Validations", value: `${metrics.successful_validations}✓ ${metrics.failed_validations}✗`, accent: "text-zinc-300" },
      { label: "Rollbacks", value: metrics.rollbacks, accent: metrics.rollbacks > 0 ? "text-red-400" : "text-zinc-500" },
      { label: "Avg Duration", value: `${Math.round(metrics.avg_duration_seconds)}s`, accent: "text-zinc-300" },
      { label: "Files Δ", value: metrics.total_files_touched, accent: "text-zinc-300" },
      { label: "Compactions", value: metrics.compaction_runs, accent: "text-violet-400" },
      { label: "Elapsed", value: `${state.elapsed_minutes}m`, accent: "text-zinc-300" },
    ].map((m, i) => (
      <div key={i} className="bg-zinc-900/80 border border-zinc-800 rounded-lg p-2 text-center">
        <div className="text-xs text-zinc-500 uppercase tracking-wider">{m.label}</div>
        <div className={`text-lg font-mono font-bold ${m.accent}`}>{m.value}</div>
      </div>
    ))}
  </div>
);

const TaskPlan = ({ tasks, currentTask }) => (
  <div className="bg-zinc-900/80 border border-zinc-800 rounded-lg overflow-hidden">
    <div className="px-4 py-2.5 border-b border-zinc-800 flex items-center justify-between">
      <h2 className="text-sm font-semibold text-zinc-300 uppercase tracking-wider">Task Plan</h2>
      <span className="text-xs text-zinc-500 font-mono">{tasks.filter(t => t.status === "done").length}/{tasks.length} complete</span>
    </div>
    <div className="divide-y divide-zinc-800/50">
      {tasks.map((task) => (
        <div
          key={task.id}
          className={`flex items-center gap-3 px-4 py-2 transition-colors ${
            task.id === currentTask ? "bg-blue-950/30 border-l-2 border-blue-500" : "border-l-2 border-transparent"
          }`}
        >
          <span className="text-xs text-zinc-600 font-mono w-16">{task.id}</span>
          <span className={`flex-1 text-sm ${task.status === "done" ? "text-zinc-500 line-through" : task.id === currentTask ? "text-zinc-200" : "text-zinc-400"}`}>
            {task.title}
          </span>
          <StatusBadge status={task.status} />
        </div>
      ))}
    </div>
  </div>
);

const HandoffViewer = ({ handoffs, selectedIdx, onSelect }) => {
  const h = handoffs[selectedIdx];
  return (
    <div className="bg-zinc-900/80 border border-zinc-800 rounded-lg overflow-hidden flex flex-col" style={{ minHeight: "400px" }}>
      <div className="px-4 py-2.5 border-b border-zinc-800 flex items-center justify-between">
        <h2 className="text-sm font-semibold text-zinc-300 uppercase tracking-wider">Handoff Documents</h2>
        <div className="flex gap-1">
          {handoffs.map((ho, i) => (
            <button
              key={i}
              onClick={() => onSelect(i)}
              className={`w-7 h-7 rounded text-xs font-mono transition-colors ${
                i === selectedIdx
                  ? "bg-blue-600 text-white"
                  : ho.validation_passed === null
                  ? "bg-amber-900/40 text-amber-400 border border-amber-800/50"
                  : ho.fully_complete
                  ? "bg-zinc-800 text-zinc-400 hover:bg-zinc-700"
                  : "bg-zinc-800 text-zinc-500 hover:bg-zinc-700 border border-dashed border-zinc-700"
              }`}
            >
              {ho.iteration}
            </button>
          ))}
        </div>
      </div>

      {h && (
        <div className="flex-1 overflow-y-auto p-4 space-y-4">
          {/* Header */}
          <div className="flex items-center gap-3">
            <span className="text-xs text-zinc-500 font-mono">{h.task_id}</span>
            <span className="text-xs text-zinc-600">•</span>
            <span className="text-xs text-zinc-500">{new Date(h.timestamp).toLocaleTimeString()}</span>
            <span className="text-xs text-zinc-600">•</span>
            <StatusBadge status={h.validation_passed === null ? "running" : h.fully_complete ? "done" : "in_progress"} />
            {h.files_touched > 0 && (
              <span className="text-xs text-zinc-600">{h.files_touched} files</span>
            )}
          </div>

          {/* Summary */}
          <div>
            <div className="text-xs text-zinc-500 uppercase tracking-wider mb-1">Summary</div>
            <div className="text-sm text-zinc-300">{h.summary}</div>
          </div>

          {/* Freeform — the core handoff prose */}
          <div className="bg-zinc-950/60 border border-zinc-800/80 rounded-lg p-3">
            <div className="text-xs text-blue-400 uppercase tracking-wider mb-2 flex items-center gap-1.5">
              <span>◆</span> Handoff Notes
            </div>
            <div className="text-sm text-zinc-300 whitespace-pre-wrap leading-relaxed font-mono" style={{ fontSize: "12.5px" }}>
              {h.freeform}
            </div>
          </div>

          {/* Structured fields */}
          {h.deviations.length > 0 && (
            <div>
              <div className="text-xs text-amber-500 uppercase tracking-wider mb-1">Deviations</div>
              {h.deviations.map((d, i) => (
                <div key={i} className="text-xs text-zinc-400 mb-1">
                  <span className="text-zinc-500">{d.planned}</span>
                  <span className="text-zinc-600"> → </span>
                  <span className="text-zinc-300">{d.actual}</span>
                  <span className="text-zinc-600"> — </span>
                  <span className="text-zinc-500 italic">{d.reason}</span>
                </div>
              ))}
            </div>
          )}

          {h.constraints.length > 0 && (
            <div>
              <div className="text-xs text-red-400 uppercase tracking-wider mb-1">Constraints Discovered</div>
              {h.constraints.map((c, i) => (
                <div key={i} className="text-xs text-zinc-400 mb-1">
                  <span className="text-zinc-300">{c.constraint}</span>
                  <span className="text-zinc-600"> — </span>
                  <span className="text-zinc-500">{c.impact}</span>
                </div>
              ))}
            </div>
          )}

          {h.architectural_notes.length > 0 && (
            <div>
              <div className="text-xs text-emerald-500 uppercase tracking-wider mb-1">Architecture</div>
              {h.architectural_notes.map((n, i) => (
                <div key={i} className="text-xs text-zinc-400 mb-1">• {n}</div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
};

const KnowledgeIndex = ({ index, mode }) => {
  if (mode === "handoff-only") {
    return (
      <div className="bg-zinc-900/80 border border-zinc-800 rounded-lg p-4">
        <div className="text-xs text-zinc-500 uppercase tracking-wider mb-2">Knowledge Index</div>
        <div className="text-xs text-zinc-600 italic">
          Disabled in handoff-only mode. Switch to handoff + knowledge index to enable periodic compaction passes that organize accumulated insights into a searchable index.
        </div>
      </div>
    );
  }
  return (
    <div className="bg-zinc-900/80 border border-zinc-800 rounded-lg overflow-hidden">
      <div className="px-4 py-2.5 border-b border-zinc-800 flex items-center justify-between">
        <h2 className="text-sm font-semibold text-zinc-300 uppercase tracking-wider">Knowledge Index</h2>
        <span className="text-xs text-violet-400 font-mono">Last organized: iter 5</span>
      </div>
      <div className="overflow-x-auto">
        <table className="w-full text-xs">
          <thead>
            <tr className="text-zinc-500 uppercase tracking-wider border-b border-zinc-800">
              <th className="px-3 py-2 text-left font-medium">Iter</th>
              <th className="px-3 py-2 text-left font-medium">Task</th>
              <th className="px-3 py-2 text-left font-medium">Summary</th>
              <th className="px-3 py-2 text-left font-medium">Tags</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-800/50">
            {index.map((entry, i) => (
              <tr key={i} className="hover:bg-zinc-800/30 transition-colors">
                <td className="px-3 py-1.5 text-zinc-500 font-mono">{entry.iteration}</td>
                <td className="px-3 py-1.5 text-zinc-500 font-mono">{entry.task}</td>
                <td className="px-3 py-1.5 text-zinc-400">{entry.summary}</td>
                <td className="px-3 py-1.5">
                  <div className="flex gap-1 flex-wrap">
                    {entry.tags.map((tag, j) => (
                      <span key={j} className="px-1.5 py-0.5 rounded bg-violet-950/50 text-violet-400 border border-violet-800/30 text-xs">
                        {tag}
                      </span>
                    ))}
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="px-4 py-2 border-t border-zinc-800 text-xs text-zinc-600">
        The coding agent receives this index as a header. It can <code className="text-zinc-400">grep</code> or read specific <code className="text-zinc-400">handoff-NNN.json</code> files for details.
      </div>
    </div>
  );
};

const GitTimeline = ({ handoffs }) => (
  <div className="bg-zinc-900/80 border border-zinc-800 rounded-lg overflow-hidden">
    <div className="px-4 py-2.5 border-b border-zinc-800">
      <h2 className="text-sm font-semibold text-zinc-300 uppercase tracking-wider">Git Timeline</h2>
    </div>
    <div className="p-4">
      <div className="flex items-center gap-0.5 overflow-x-auto pb-2">
        {handoffs.map((h, i) => (
          <div key={i} className="flex items-center">
            <div
              className={`w-4 h-4 rounded-full border-2 flex-shrink-0 ${
                h.validation_passed === null
                  ? "border-amber-500 bg-amber-500/20"
                  : h.validation_passed
                  ? "border-emerald-500 bg-emerald-500/20"
                  : "border-red-500 bg-red-500/20"
              }`}
              title={`Iteration ${h.iteration}: ${h.task_id}`}
            />
            {i < handoffs.length - 1 && (
              <div className="w-6 h-0.5 bg-zinc-700 flex-shrink-0" />
            )}
          </div>
        ))}
      </div>
      <div className="flex justify-between text-xs text-zinc-600 mt-1 font-mono">
        <span>iter 1</span>
        <span>iter {handoffs.length}</span>
      </div>
    </div>
  </div>
);

const ArchDiagram = ({ mode }) => (
  <div className="bg-zinc-900/80 border border-zinc-800 rounded-lg overflow-hidden">
    <div className="px-4 py-2.5 border-b border-zinc-800">
      <h2 className="text-sm font-semibold text-zinc-300 uppercase tracking-wider">
        Architecture — {mode === "handoff-only" ? "Handoff Only" : "Handoff + Knowledge Index"}
      </h2>
    </div>
    <div className="p-4 font-mono text-xs leading-relaxed">
      {mode === "handoff-only" ? (
        <pre className="text-zinc-400 overflow-x-auto">{`
  ┌─────────────────────────────────────────────┐
  │               ralph.sh loop                 │
  │                                             │
  │  1. Read plan.json → next pending task      │
  │  2. Assemble prompt:                        │
  │     • task description                      │
  │     • previous handoff (verbatim)           │
  │     • skill files                           │
  │  3. Create git checkpoint                   │
  │  4. claude -p → coding iteration            │
  │  5. Parse handoff from structured output    │
  │  6. Run validation                          │
  │  7. Pass → commit │ Fail → rollback         │
  │  8. Save handoff → handoffs/NNN.json        │
  │  9. Loop                                    │
  │                                             │
  │  Three artifacts:                           │
  │  ┌──────┐  ┌─────────┐  ┌─────────────┐    │
  │  │ Plan │→ │ Handoff  │→ │ Next prompt │    │
  │  └──────┘  └─────────┘  └─────────────┘    │
  └─────────────────────────────────────────────┘`}</pre>
      ) : (
        <pre className="text-zinc-400 overflow-x-auto">{`
  ┌─────────────────────────────────────────────┐
  │               ralph.sh loop                 │
  │                                             │
  │  CODING ITERATION (most loops):             │
  │  1. Read plan.json → next pending task      │
  │  2. Assemble prompt:                        │
  │     • task description                      │
  │     • previous handoff (verbatim)           │
  │     • knowledge index header (lightweight)  │
  │     • skill files                           │
  │  3. Checkpoint → claude -p → validate       │
  │  4. Commit/rollback → save handoff          │
  │                                             │
  │  COMPACTION ITERATION (every N loops):      │
  │  1. Read all handoffs since last compaction  │
  │  2. claude -p → organize into index         │
  │  3. Output: index entries + tagged summaries │
  │  4. Agent does NOT inject — just indexes     │
  │                                             │
  │  Three artifacts + index:                   │
  │  ┌──────┐  ┌─────────┐  ┌───────┐          │
  │  │ Plan │  │ Handoff  │  │ Index │          │
  │  └──┬───┘  └────┬────┘  └───┬───┘          │
  │     └─────┬─────┘           │               │
  │     ┌─────▼─────┐    ┌─────▼─────┐         │
  │     │Next prompt │    │ grep/read │         │
  │     │(plan+hand) │    │ on demand │         │
  │     └───────────┘    └───────────┘         │
  └─────────────────────────────────────────────┘`}</pre>
      )}
    </div>
  </div>
);

// --- Main Dashboard ---

export default function RalphDeluxeDashboard() {
  const [mode, setMode] = useState(MOCK_STATE.mode);
  const [selectedHandoff, setSelectedHandoff] = useState(MOCK_HANDOFFS.length - 1);
  const [activeTab, setActiveTab] = useState("dashboard");
  const [pulse, setPulse] = useState(true);

  useEffect(() => {
    const timer = setInterval(() => setPulse((p) => !p), 1500);
    return () => clearInterval(timer);
  }, []);

  const toggleMode = () => {
    setMode((m) => (m === "handoff-only" ? "handoff-plus-index" : "handoff-only"));
  };

  return (
    <div className="min-h-screen bg-zinc-950 text-zinc-300" style={{ fontFamily: "'JetBrains Mono', 'SF Mono', 'Fira Code', monospace" }}>
      {/* Header */}
      <div className="border-b border-zinc-800 bg-zinc-950/95 sticky top-0 z-50">
        <div className="max-w-7xl mx-auto px-4 py-3 flex items-center justify-between">
          <div className="flex items-center gap-4">
            <h1 className="text-lg font-bold tracking-tight">
              <span className="text-blue-400">Ralph</span>
              <span className="text-zinc-500"> Deluxe</span>
              <span className="text-zinc-700 text-xs ml-2">v2</span>
            </h1>
            <div className="flex items-center gap-2">
              <div
                className={`w-2 h-2 rounded-full ${
                  MOCK_STATE.status === "running"
                    ? pulse ? "bg-emerald-400" : "bg-emerald-600"
                    : "bg-zinc-600"
                }`}
              />
              <StatusBadge status={MOCK_STATE.status} />
            </div>
          </div>

          <div className="flex items-center gap-3">
            <ModeToggle mode={mode} onToggle={toggleMode} />
            <div className="flex rounded-lg overflow-hidden border border-zinc-800">
              {["dashboard", "architecture"].map((tab) => (
                <button
                  key={tab}
                  onClick={() => setActiveTab(tab)}
                  className={`px-3 py-1.5 text-xs uppercase tracking-wider transition-colors ${
                    activeTab === tab ? "bg-zinc-800 text-zinc-200" : "text-zinc-500 hover:text-zinc-300"
                  }`}
                >
                  {tab}
                </button>
              ))}
            </div>
          </div>
        </div>
      </div>

      {/* Content */}
      <div className="max-w-7xl mx-auto px-4 py-4 space-y-4">
        {activeTab === "dashboard" ? (
          <>
            <MetricsStrip metrics={MOCK_METRICS} state={MOCK_STATE} />

            <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
              {/* Left column: Task Plan */}
              <div className="lg:col-span-1 space-y-4">
                <TaskPlan tasks={MOCK_PLAN} currentTask={MOCK_STATE.current_task} />
                <GitTimeline handoffs={MOCK_HANDOFFS} />
              </div>

              {/* Right column: Handoff viewer + Knowledge Index */}
              <div className="lg:col-span-2 space-y-4">
                <HandoffViewer
                  handoffs={MOCK_HANDOFFS}
                  selectedIdx={selectedHandoff}
                  onSelect={setSelectedHandoff}
                />
                <KnowledgeIndex index={MOCK_INDEX} mode={mode} />
              </div>
            </div>
          </>
        ) : (
          <ArchDiagram mode={mode} />
        )}

        {/* Footer info */}
        <div className="border-t border-zinc-800 pt-3 pb-6 flex items-center justify-between text-xs text-zinc-600">
          <div>
            Handoff-first orchestration • Plan + Handoff + {mode === "handoff-only" ? "no compaction" : "Knowledge Index"}
          </div>
          <div>
            Polling state.json every 3s • {mode === "handoff-plus-index" ? "Compaction every 5 coding iterations" : "No compaction overhead"}
          </div>
        </div>
      </div>
    </div>
  );
}
