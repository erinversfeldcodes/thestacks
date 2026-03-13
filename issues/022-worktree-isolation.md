# Issue #022: Worktree Isolation Per Specialist

## Summary
Each specialist agent works in its own git worktree branched from the feature branch. Parallel specialists cannot step on each other's files, failed implementations can be discarded cleanly, and the orchestrator merges approved worktrees as the commit gate.

## User Stories
Not directly tied to a user story — internal tooling for the agent-driven development workflow.

## Goal
Three specialists (database migrations, API endpoints, frontend components) work simultaneously on a feature without merge conflicts. A specialist whose phase fails review is re-run in a clean worktree without affecting other in-progress or approved work.

## Technical Requirements

### 22.1 — Worktree Lifecycle

For each specialist phase:
1. Orchestrator creates a worktree: `git worktree add .claude/worktrees/<issue>-phase-<N> <feature-branch>`
2. Specialist is invoked with `worktree_path` so it works in that directory
3. On APPROVED: orchestrator merges the worktree branch into the feature branch, removes the worktree
4. On NEEDS_REVISION: orchestrator either keeps the worktree for the revision or creates a fresh one
5. On phase complete: `git worktree remove .claude/worktrees/<issue>-phase-<N>`

`.claude/worktrees/` is already gitignored.

### 22.2 — MCP Tool: `create_worktree` / `remove_worktree`

Add to `scripts/mcp/project_tools.py`:

```python
create_worktree(issue_number: int, phase: str) -> dict
# Returns {"path": ".claude/worktrees/014-phase-2", "branch": "worktree/014-phase-2"}

remove_worktree(issue_number: int, phase: str) -> dict
# Removes worktree and branch
```

### 22.3 — Orchestrator Protocol Update

Phase 2A gains worktree creation step. Phase 2D (APPROVED path) gains merge + remove step. Specialist invocation prompt includes `worktree_path` when isolation is active.

The orchestrator state file tracks active worktrees per phase.

### 22.4 — Parallel Phase Execution

When the plan has independent phases (no data dependency between them), the orchestrator may delegate multiple specialists simultaneously:
- Each gets its own worktree
- Orchestrator waits for all completion reports before running review
- Independent reviewers run in parallel
- Merges happen in dependency order

Parallel execution is opt-in per plan — the orchestrator notes in the plan which phases are independent.

### 22.5 — Worktree-Aware Test Suite

`run_test_suite` (Issue #020) accepts `worktree_path` so the regression gate runs against the specialist's isolated changes, not the main branch.

### 22.6 — Settings Configuration

`.claude/settings.json` gains a worktree symlinks configuration to avoid duplicating large directories:

```json
{
  "worktree": {
    "symlinkDirectories": ["deps", "_build", "node_modules", "apps/vision/.venv"]
  }
}
```

## Definition of Done

- [ ] `create_worktree` and `remove_worktree` MCP tools implemented
- [ ] Orchestrator Phase 2A updated with worktree creation step
- [ ] Orchestrator Phase 2D APPROVED path updated with merge + remove step
- [ ] Orchestrator state file updated to track active worktrees per phase
- [ ] `.claude/settings.json` worktree symlink config added
- [ ] Parallel phase execution documented in orchestrator plan style guide
- [ ] At least one phase run in an isolated worktree

## Dependencies
- Issue #016 (MCP server) — extends project_tools.py
- Issue #017 (structured state files) — worktree paths tracked in state file
- Issue #020 (regression gate) — `run_test_suite` worktree_path param

## Agent Assignment
- **python-agent** for MCP tools
- **platform-agent** for orchestrator-agent.md and settings.json

## Progress Notes
<!-- Updated by agents during execution -->
- 2026-03-13: Issue created from agentic techniques feedback.
