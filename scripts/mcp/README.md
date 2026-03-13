# Project Tools MCP Server

A lightweight MCP server that exposes The Stacks project-management operations as first-class tools in every Claude Code session. Agents call `get_issue(14)` instead of reading and parsing markdown files. Context window saved, parsing errors eliminated.

## Tools

| Tool | Description |
|------|-------------|
| `get_issue(number)` | Parse an issue file → structured metadata (title, DoD, progress notes, agent assignment) |
| `list_issues(status?)` | List all issues filtered by `"open"`, `"complete"`, or `"all"` |
| `next_issue_number()` | Return the next available issue number |
| `update_progress(number, note)` | Append a `- YYYY-MM-DD: <note>` line to an issue's Progress Notes section |
| `get_plan_status(issue_number)` | Read a plan file and return its declared status and phase list |
| `get_agent(name)` | Read an agent spec → role, owned domains, and full content |
| `create_issue(title, summary, ...)` | Create a new issue file from the template, returning the number |

## Setup

The server requires Python 3.10+ and the `mcp` package. A virtual environment lives at `scripts/mcp/.venv/` (gitignored).

```bash
# Create the venv and install dependencies
python3 -m venv scripts/mcp/.venv
scripts/mcp/.venv/bin/pip install -r scripts/mcp/requirements.txt
```

Or if your system Python is too old (macOS ships 3.9):

```bash
/opt/homebrew/bin/python3.13 -m venv scripts/mcp/.venv
scripts/mcp/.venv/bin/pip install -r scripts/mcp/requirements.txt
```

## Registration

The server is registered in `.mcp.json` and auto-approved via `.claude/settings.json`:

```json
// .mcp.json
{
  "mcpServers": {
    "project-tools": {
      "command": "bash",
      "args": ["$CLAUDE_PROJECT_DIR/scripts/mcp/server.sh"]
    }
  }
}
```

Claude Code starts the server on demand when a session opens. Tools are available as `mcp__project-tools__get_issue`, etc.

## Testing locally

```bash
# Run all DoD tests
scripts/mcp/.venv/bin/python -c "
from scripts.mcp.project_tools import get_issue, list_issues, next_issue_number
print(get_issue(16))
print(list_issues('open'))
print(next_issue_number())
"

# Or exercise the MCP protocol directly via the MCP CLI (if installed)
scripts/mcp/.venv/bin/python scripts/mcp/project_tools.py
```

## Adding new tools

1. Add a function decorated with `@mcp.tool()` to `project_tools.py`
2. Type-annotate parameters — FastMCP generates the JSON schema from annotations
3. Return a dict or list; FastMCP serialises it to the MCP response format
4. Test by importing the function directly before wiring it through the protocol

## File layout

```
scripts/mcp/
├── project_tools.py   # MCP server — all tool implementations
├── server.sh          # Entry point: activates .venv, runs project_tools.py
├── requirements.txt   # Pinned: mcp>=1.26.0
├── .venv/             # Local venv (gitignored)
└── README.md          # This file
```
