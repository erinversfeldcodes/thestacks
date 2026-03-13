# Plan: Worktree Isolation Per Specialist
**Issue**: #022
**Created**: 2026-03-13
**Status**: Approved

## Context
Each specialist agent works in its own git worktree branched from the feature branch. Parallel specialists cannot step on each other's files, failed implementations can be discarded cleanly, and the orchestrator merges approved worktrees as the commit gate.

## Research Summary
`.claude/worktrees/` is already gitignored. The `run_test_suite` tool (Issue #020) already accepts an optional `worktree_path` parameter. The orchestrator state file schema tracks phases but not worktree paths — needs a `worktree_path` field per phase. Settings file has hooks config but no worktree section.

## Approach Options
- **Option A (chosen):** Git worktrees via MCP tools + orchestrator protocol. Recommended.
- **Option B:** Docker containers — massive overhead. Not recommended.
- **Option C:** Branch-per-specialist without worktrees — no parallelism. Not recommended.

## Phases

### Phase 1: MCP Tools
**Objective**: Implement `create_worktree` and `remove_worktree` in `scripts/mcp/project_tools.py`
**Agent(s)**: python-agent
**Steps**:
1. Implement `create_worktree(issue_number: int, phase: str) -> dict` — runs `git worktree add`, returns `{"path": "...", "branch": "..."}`
2. Implement `remove_worktree(issue_number: int, phase: str) -> dict` — runs `git worktree remove` and deletes branch
3. Handle edge cases: worktree already exists, worktree not found, git errors
4. Write tests for both tools
**Test Command**: `cd scripts/mcp && .venv/bin/python -m unittest test_project_tools.py`
**DoD Items**:
- [ ] `create_worktree` and `remove_worktree` MCP tools implemented
- [ ] Tools tested

### Phase 2: Orchestrator Protocol + Settings
**Objective**: Update orchestrator for worktree lifecycle, parallel execution, state tracking, and settings
**Agent(s)**: platform-agent
**Steps**:
1. Update Phase 2A-i to include worktree creation step before delegating
2. Update Phase 2D APPROVED path to include merge + remove step
3. Update state file schema to include `worktree_path` per phase
4. Add parallel phase execution guidance to plan style guide
5. Add worktree symlink config to `.claude/settings.json`
**Test Command**: N/A (documentation + config only)
**DoD Items**:
- [ ] Orchestrator Phase 2A updated with worktree creation step
- [ ] Orchestrator Phase 2D APPROVED path updated with merge + remove step
- [ ] Orchestrator state file updated to track active worktrees per phase
- [ ] Parallel phase execution documented in orchestrator plan style guide
- [ ] `.claude/settings.json` worktree symlink config added

## Open Questions
None.

## Integration Handoffs
Phase 1 produces MCP tools. Phase 2 references them in orchestrator protocol. Phase 2 depends on Phase 1.
