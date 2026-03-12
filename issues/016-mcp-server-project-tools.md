# Issue #016: MCP Server for Project-Specific Agent Tools

## Summary
The orchestrator and specialist agents repeatedly perform the same multi-step operations in every session: parse issue files, determine the next issue number, append progress notes, check plan status. These are error-prone when done via markdown parsing and consume context window on boilerplate. A lightweight project-local MCP server exposes these as first-class tools.

## User Stories
Not directly tied to a user story — internal tooling for the agent-driven development workflow.

## Goal
Agents call `get_issue(14)` instead of reading and parsing `issues/014-*.md` themselves. `update_progress(14, "note")` appends correctly formatted progress notes without the agent needing to know the file path or markdown structure. Issue creation, plan status checks, and agent assignment lookups become single tool calls rather than multi-step file operations. Context window saved, parsing errors eliminated.

## Technical Requirements

### 16.1 — MCP Server Implementation

A local MCP server implemented as a Node.js or Python script in `scripts/mcp/`. It is registered in `.claude/settings.json` as a local MCP server and is available in every Claude Code session without additional setup.

**Runtime:** Python (already in the project stack; no new dependency). Uses `mcp` SDK (`pip install mcp`).

**Entry point:** `scripts/mcp/project_tools.py`

### 16.2 — Tools to Expose

#### `get_issue(number: int) → IssueMetadata`
Reads `issues/{NNN}-*.md`, parses the structured sections, and returns:
```json
{
  "number": 14,
  "title": "Agent System Improvements",
  "summary": "...",
  "status": "open",
  "agent_assignment": "orchestrator",
  "dod_items": [
    {"text": "orchestrator-agent.md updated", "done": false}
  ],
  "dependencies": [],
  "progress_notes": ["2026-03-13: Issue created..."]
}
```

#### `list_issues(status?: "open"|"complete"|"all") → Issue[]`
Returns all issues with their number, title, and DoD completion ratio. Used by the orchestrator to get a project status overview.

#### `next_issue_number() → int`
Scans `issues/` and returns the next available issue number. Eliminates the repeated `ls issues/` + manual counting pattern.

#### `update_progress(number: int, note: str) → void`
Appends a timestamped progress note to the issue file's `## Progress Notes` section. Format: `- {YYYY-MM-DD}: {note}`. Handles the file write atomically.

#### `get_plan_status(issue_number: int) → PlanStatus`
Reads `plans/{NNN}-*.md` (if it exists) and returns:
```json
{
  "exists": true,
  "current_phase": "1B",
  "phases": [
    {"id": "1A", "status": "complete"},
    {"id": "1B", "status": "in_progress"},
    {"id": "1C", "status": "pending"}
  ],
  "last_updated": "2026-03-13"
}
```

#### `get_agent(name: str) → AgentSpec`
Reads `docs/agents/{name}-agent.md` and returns the agent's role, owned domains, and pre-approved commands. Used by the orchestrator when constructing specialist invocation prompts.

#### `create_issue(title: str, summary: str, ...) → int`
Creates a new issue file from the template with the next available number. Returns the number. Replaces the manual "read template, copy, fill in" pattern.

### 16.3 — Registration in Claude Code

In `.claude/settings.json`:
```json
{
  "mcpServers": {
    "project-tools": {
      "command": "python3",
      "args": ["scripts/mcp/project_tools.py"],
      "cwd": "/Users/erinversfeld/thestacks"
    }
  }
}
```

The server starts on demand when Claude Code launches and is available as `mcp__project-tools__get_issue` etc.

### 16.4 — Error Handling

- `get_issue(999)` for a non-existent issue returns a clear error, not a file-not-found stack trace
- `update_progress` validates the note is non-empty and the issue exists before writing
- All tools return structured errors the agent can interpret and act on

### 16.5 — No External Dependencies Beyond `mcp`

The server reads files directly — no database, no index file to maintain. Issue and plan files are the source of truth. Adding the `mcp` package to `scripts/mcp/requirements.txt` is the only new dependency.

## Definition of Done

- [ ] `scripts/mcp/project_tools.py` implemented with all 6 tools
- [ ] `scripts/mcp/requirements.txt` with pinned `mcp` version
- [ ] Server registered in `.claude/settings.json`
- [ ] `get_issue`, `list_issues`, `next_issue_number` tested against real issue files
- [ ] `update_progress` tested: appends correctly, does not corrupt existing content
- [ ] `get_plan_status` tested against a real plan file
- [ ] `create_issue` tested: creates valid file, returns correct number
- [ ] Error cases tested: non-existent issue, malformed markdown, missing plan
- [ ] `scripts/mcp/README.md` documents how to run and test the server locally

## Dependencies
- Issue #015 (Claude Code hooks) — both modify `.claude/settings.json`; coordinate to avoid conflicts

## Agent Assignment
- **python-agent** (`docs/agents/python-agent.md`) for the MCP server implementation
- **platform-agent** (`docs/agents/platform-agent.md`) for `.claude/settings.json` registration
- **Reviewer**: python-reviewer + platform-reviewer

## Progress Notes
<!-- Updated by agents during execution -->
- 2026-03-13: Issue created from agentic techniques gap analysis.
