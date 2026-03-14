# Issue #039: Orchestrator Commit Verification Protocol

## Summary
Fixes applied to the working tree but never committed get lost on branch switches. The same fixes (modal cleanup command, subprocess shell=True, mypy type: ignore) were re-applied 2-3 times across Issues #007 and #011. Add a commit verification step to the orchestrator protocol to prevent this class of work loss.

## User Stories
N/A — agent system infrastructure.

## Goal
The orchestrator protocol requires verification that fixes are committed before proceeding to the next phase or switching branches. No fix should exist only in the working tree at the end of a phase.

## Technical Requirements

### Problem
During Issues #007 and #011, the following fixes were applied to the working tree but never committed:
- `scripts/cleanup-preview.sh`: `modal app delete` → `modal app stop` (applied 3 times)
- `scripts/mcp/project_tools.py`: `shell=True` → list-based commands (applied 2 times)
- `apps/vision/app/services/local_ocr.py`: `type: ignore[import-untyped]` (applied 2 times)
- `scripts/hooks/pre-commit`: elm-format resolution (applied, then lost on branch copy)

Each re-application cost 5-10 minutes of debugging ("why is this still failing?").

### Fix: Add commit verification to orchestrator protocol

Update `docs/agents/orchestrator-agent.md` in two places:

**1. Phase 2D (Act on Review Result) — after "MANDATORY STOP":**

Add: "Before proceeding to the next phase, verify all fixes from this phase are committed by running `git status`. If uncommitted changes exist that are part of this phase's work, prompt the human to commit them. Do not proceed with uncommitted phase work."

**2. Phase 2E (Next Phase) — before starting next phase:**

Add: "If the next phase requires switching branches or worktrees, verify the current branch has no uncommitted changes from previous phases. Uncommitted fixes will be lost on branch switch."

**3. New section: "Working Tree Hygiene":**

Add a new section to the orchestrator protocol:
```
## Working Tree Hygiene

Fixes applied during a phase (bug fixes, linting corrections, config changes) must be committed
before the phase is considered complete. The orchestrator must:

1. After each phase completion, run `git status` to check for uncommitted changes
2. If changes exist, present them to the human and request a commit
3. Do not mark a phase as complete while uncommitted changes from that phase exist
4. Before switching branches or creating worktrees, verify clean working tree
```

## Definition of Done
- [ ] `docs/agents/orchestrator-agent.md` Phase 2D updated with commit verification step
- [ ] `docs/agents/orchestrator-agent.md` Phase 2E updated with branch-switch guard
- [ ] New "Working Tree Hygiene" section added to orchestrator protocol
- [ ] State file schema updated: phase completion requires `committed: true` field

## Dependencies
None — documentation and protocol changes only.

## Agent Assignment
- **Orchestrator** (direct edit — no specialist needed)
- **Reviewer**: Manual review by human

## Progress Notes
<!-- Updated by agents during execution -->
