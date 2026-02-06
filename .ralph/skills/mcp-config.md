# MCP Configuration Reference

## Strict Mode
`--strict-mcp-config` means ONLY the MCP servers listed in the config file are available. No other MCP servers will be loaded. This provides isolation between iteration types.

## Config File Flag
`--mcp-config path.json` specifies which MCP config file to use.

## Coding Iterations
Use `mcp-coding.json` which has an empty `mcpServers` object:
```bash
claude -p --strict-mcp-config --mcp-config .ralph/config/mcp-coding.json ...
```
Coding iterations use only Claude Code's built-in tools (Read, Edit, Bash, Grep, Glob). No external MCP servers. This keeps the context clean and avoids startup overhead.

## Memory Iterations
Use `mcp-memory.json` which includes Context7 and Knowledge Graph Memory Server:
```bash
claude -p --strict-mcp-config --mcp-config .ralph/config/mcp-memory.json ...
```

## Context7 Usage
Two-step process — do NOT skip the first step:
1. **Resolve the library ID**: Call `resolve-library-id` with the library name (e.g., "react"). Returns the Context7-compatible ID.
2. **Fetch documentation**: Call `get-library-docs` with the resolved ID. Returns relevant API docs and usage examples.

Always resolve first, then fetch. The library name alone is not a valid ID.

## Knowledge Graph Memory Server
Stores entities and relations in `.ralph/memory.jsonl` for cross-session persistence.

Key tools:
- `create_entities`: Store named entities with type and observations
  ```json
  [{"name": "git-ops.sh", "entityType": "module", "observations": ["Handles checkpoint and rollback"]}]
  ```
- `create_relations`: Link entities together
  ```json
  [{"from": "git-ops.sh", "to": "checkpoint pattern", "relationType": "implements"}]
  ```
- `search_nodes`: Query existing knowledge before creating duplicates
  ```json
  {"query": "validation"}
  ```
