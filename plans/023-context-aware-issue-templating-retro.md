# Retrospective: Context-Aware Issue Templating
**Issue**: #023
**Date**: 2026-03-13
**Phases completed**: 2
**Agents involved**: python-agent (Phase 1), platform-agent (Phase 2)

---

## What Worked Well

- **Orchestrator handled Phase 2 directly**: The orchestrator doc edit was small enough (one step change + renumbering) that delegating to a subagent would have been overhead. Editing directly was faster and correct on first attempt.
- **Separate templates module**: Putting DoD templates in `dod_templates.py` rather than inline in `project_tools.py` keeps the MCP server focused on tool logic. The templates are easy to extend when new domains are added.
- **MCP test suite at 39 tests**: Six issues of MCP development (#016, #018-#023) have built a comprehensive test suite. Each new tool gets tested in isolation without breaking existing tools.
- **Clean dependency detection**: Using keyword matching on open issue titles + agent assignment overlap is simple and effective. No over-engineering with NLP or embedding similarity.

---

## What Caused Friction

- **Step renumbering in Phase 0**: Inserting a new step 3 (draft_issue) before the old step 3 (create_issue) required careful renumbering of steps 4-7. A duplicate step 5 appeared and had to be fixed. This is inherent to numbered lists in markdown — fragile under insertion.
- **`draft_issue` returns `suggested_dependencies` as extra field**: The return dict has both `dependencies` (formatted string for `create_issue`) and `suggested_dependencies` (structured list for human review). This dual representation could confuse — the human sees one format, `create_issue` expects another.

---

## What Should Change in the Agent System

| File | Change | Addresses friction point |
|------|--------|--------------------------|
| `docs/agents/orchestrator-agent.md` | Consider using lettered sub-steps instead of renumbering when inserting into Phase 0 (e.g., 3a, 3b) | Step renumbering fragility |
| `scripts/mcp/project_tools.py` | Simplify `draft_issue` return to only include `suggested_dependencies` as the structured list; let the orchestrator format the `dependencies` string when calling `create_issue` | Dual dependency representation |

---

## Suggested Issues

- [ ] MCP tool documentation — Add inline help/examples to each MCP tool's docstring so Claude Code's tool discovery surfaces usage patterns
