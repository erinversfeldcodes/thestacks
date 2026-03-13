# Issue #023: Context-Aware Issue Templating

## Summary
When the orchestrator creates an issue from the roadmap, it currently relies on the human and orchestrator to manually cross-reference the codebase. A `draft_issue` MCP tool pre-populates Technical Requirements by reading the current codebase state — which modules will be touched, what architectural constraints apply, which downstream issues depend on this.

## User Stories
Not directly tied to a user story — internal tooling for the agent-driven development workflow.

## Goal
The orchestrator calls `draft_issue(roadmap_item)` and receives a populated issue draft with relevant existing modules identified, applicable standards referenced, and dependency relationships surfaced. Human review time at the mandatory stop is reduced because the draft already contains accurate context rather than placeholders.

## Technical Requirements

### 23.1 — MCP Tool: `draft_issue`

Add to `scripts/mcp/project_tools.py`:

```python
draft_issue(
    title: str,
    roadmap_context: str,
    domains: list[str],
) -> dict
```

Returns a pre-populated issue dict (same shape as `create_issue` inputs) with:

- **`technical_requirements`**: Populated with relevant existing modules, schema names, and standards references derived from the domains list
- **`dependencies`**: Issues from `list_issues()` whose titles/domains suggest a dependency relationship
- **`agent_assignment`**: Derived from the AGENTS.md domain routing table (read via `get_agent`)
- **`dod_items`**: Standard DoD items for the domain(s), e.g. Elixir phases always include "mix test passing", "mix credo --strict clean", "sobelow scan clean"

### 23.2 — Domain-Aware DoD Templates

Each domain has a standard DoD item set that is always included. Store in `scripts/mcp/dod_templates.py`:

```python
DOD_TEMPLATES = {
    "elixir": [
        "mix test passing with no new skips",
        "mix credo --strict clean",
        "sobelow scan clean",
        "typespecs on all public functions",
        "events emitted for all state changes",
    ],
    "elm": [
        "elm-test passing",
        "elm-format clean",
        "RemoteData used for all API calls",
    ],
    "rust": [
        "cargo test passing",
        "cargo fmt clean",
        "cargo clippy -- -D warnings clean",
    ],
    "python": [
        "pytest passing",
        "ruff format and check clean",
        "type annotations on all functions",
    ],
    # ...
}
```

### 23.3 — Dependency Detection

`draft_issue` scans `list_issues(status="open")` and flags issues as potential dependencies when:
- Their title contains keywords matching the new issue's domains
- Their agent_assignment overlaps
- The human has not yet merged them (open status)

These are returned as suggestions, not hard dependencies — the human confirms at the mandatory stop.

### 23.4 — Orchestrator Integration

Phase 0 step 3 changes from calling `create_issue(...)` directly to calling `draft_issue(...)` first, presenting the draft to the human for review, then calling `create_issue(...)` with the approved content. This preserves the mandatory stop while reducing the manual cross-referencing work.

## Definition of Done

- [ ] `draft_issue` MCP tool implemented
- [ ] `scripts/mcp/dod_templates.py` with domain DoD templates for elixir, elm, rust, python, platform, database
- [ ] Dependency detection logic implemented and tested against existing issue set
- [ ] Orchestrator Phase 0 step 3 updated to use `draft_issue` before `create_issue`
- [ ] Tool tested: draft for an elixir domain issue includes correct DoD items and surfaces relevant open issues

## Dependencies
- Issue #016 (MCP server) — extends project_tools.py

## Agent Assignment
- **python-agent** for MCP tool and dod_templates.py
- **platform-agent** for orchestrator-agent.md

## Progress Notes
<!-- Updated by agents during execution -->
- 2026-03-13: Issue created from agentic techniques feedback.
