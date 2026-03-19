# Issue #040: Worktree Agents Write to Main Tree via Absolute Paths

## Summary
Agents spawned in isolated worktrees resolve file paths back to the main repository tree, defeating worktree isolation. When multiple agents run in parallel, their changes land on the same working tree — creating merge conflicts and losing the isolation benefit that worktrees are supposed to provide.

## User Stories
N/A — agent system infrastructure.

## Goal
Agents running in worktrees write exclusively to their worktree's file system. No changes from a worktree agent should appear in the main tree until explicitly merged.

## Technical Requirements

### Problem
The `.claude/settings.json` `symlinkDirectories` setting is intended for build artifacts only (`deps`, `_build`, `node_modules`, `.venv`). However, when agents are launched with `isolation: "worktree"`, they receive absolute paths in their prompts (e.g., `/Users/erinversfeld/thestacks/docs/agents/orchestrator-agent.md`) and write to those paths directly — which resolve to the main tree, not the worktree.

This was observed in Issue #011 (6 worktree agents ran in parallel; all doc/script changes landed on the main tree simultaneously) and caused:
- 6 agents' changes to `orchestrator-agent.md` interleaved without conflict resolution
- Changes to `scripts/mcp/project_tools.py` from multiple agents overwrote each other
- No isolation between worktrees for any file outside `apps/` and `frontend/`

### Root cause
Two contributing factors:
1. **Prompt paths are absolute**: The orchestrator passes absolute paths like `/Users/.../thestacks/docs/...` in agent prompts. Agents write to these paths, which resolve to the main tree regardless of worktree CWD.
2. **`CLAUDE_PROJECT_DIR` resolves to main tree**: Hooks and tools reference `$CLAUDE_PROJECT_DIR` which points to the main repo, not the worktree.

### Proposed fix
1. When constructing agent prompts for worktree-isolated agents, use paths relative to the worktree root (or replace the repo root prefix with the worktree path)
2. Investigate whether Claude Code's `isolation: "worktree"` sets CWD to the worktree — if so, agents should use relative paths
3. Consider removing `symlinkDirectories` entirely and accepting the build-time cost, since symlinks create a shared-state channel between worktrees

### Workaround (current)
For issues where agents touch the same files (e.g., `orchestrator-agent.md`), run them **sequentially** rather than in parallel — the isolation benefit is lost anyway when paths resolve to the same tree.

## Definition of Done
- [x] Worktree agents write exclusively to their worktree's file system
- [x] Parallel worktree agents do not interfere with each other's files
- [x] `symlinkDirectories` only symlinks build artifacts, not source/doc files (removed from settings.json — was never implemented)
- [x] Orchestrator prompt construction uses worktree-relative paths when `isolation: "worktree"` is set
- [x] Verified: `grep -r "/Users/erinversfeld/thestacks/" docs/agents/ --include="*.md"` returns zero matches; all 23 agent specs now use `./`-relative paths

## Dependencies
None.

## Agent Assignment
- **platform-agent** (investigation + fix)
- **Reviewer**: Manual review by human

## Progress Notes
<!-- Updated by agents during execution -->
