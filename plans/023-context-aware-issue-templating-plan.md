# Plan: Context-Aware Issue Templating
**Issue**: #023
**Created**: 2026-03-13
**Status**: Approved

## Context
The orchestrator's Phase 0 currently relies on manual cross-referencing when creating issues. A `draft_issue` MCP tool pre-populates Technical Requirements, DoD items, agent assignment, and dependency suggestions by reading the codebase and existing issues.

## Research Summary
The MCP server has `create_issue`, `list_issues`, and `get_agent` tools already. `draft_issue` builds on these — calling `list_issues` for dependency detection and using the AGENTS.md domain routing table for agent assignment. DoD templates are domain-specific checklists that every issue in that domain should include.

## Approach Options
- **Option A (chosen):** `draft_issue` MCP tool + separate DoD templates module + orchestrator Phase 0 update. Recommended.
- **Option B:** Inline templates in project_tools.py — harder to maintain. Not recommended.
- **Option C:** AI-powered draft — over-engineered. Not recommended.

## Phases

### Phase 1: DoD Templates + MCP Tool
**Objective**: Create `dod_templates.py` and implement `draft_issue` tool with dependency detection
**Agent(s)**: python-agent
**Steps**:
1. Create `scripts/mcp/dod_templates.py` with DOD_TEMPLATES dict for 6 domains (elixir, elm, rust, python, platform, database)
2. Implement `draft_issue(title, roadmap_context, domains)` in project_tools.py
3. Tool reads DOD_TEMPLATES for domain-specific DoD items
4. Tool calls `list_issues(status="open")` for dependency detection (keyword + domain overlap)
5. Tool derives agent_assignment from AGENTS.md domain routing table
6. Tool returns dict matching `create_issue` input shape
7. Write tests for DoD template loading, dependency detection, and full draft generation
**Test Command**: `cd scripts/mcp && .venv/bin/python -m unittest test_project_tools.py`
**DoD Items**:
- [ ] `draft_issue` MCP tool implemented
- [ ] `scripts/mcp/dod_templates.py` with domain DoD templates for elixir, elm, rust, python, platform, database
- [ ] Dependency detection logic implemented and tested
- [ ] Tool tested: draft for an elixir domain issue includes correct DoD items and surfaces relevant open issues

### Phase 2: Orchestrator Phase 0 Update
**Objective**: Update Phase 0 step 3 to use `draft_issue` before `create_issue`
**Agent(s)**: platform-agent
**Steps**:
1. Update Phase 0 step 3 to call `draft_issue(title, roadmap_context, domains)` first
2. Present the draft to the human for review at the existing mandatory stop
3. On approval, call `create_issue(...)` with the approved/modified content
**Test Command**: N/A (documentation only)
**DoD Items**:
- [ ] Orchestrator Phase 0 step 3 updated to use `draft_issue` before `create_issue`

## Open Questions
None.

## Integration Handoffs
Phase 1 produces the MCP tool. Phase 2 references it in orchestrator protocol. Phase 2 depends on Phase 1.
