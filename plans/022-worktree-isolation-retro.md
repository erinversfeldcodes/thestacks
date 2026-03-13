# Retrospective: Worktree Isolation Per Specialist
**Issue**: #022
**Date**: 2026-03-13
**Phases completed**: 2
**Agents involved**: python-agent (Phase 1), platform-agent (Phase 2)

---

## What Worked Well

- **Consistent MCP pattern**: The python-agent followed the exact same patterns established in #020 (subprocess.run, error dicts, helper functions). The growing MCP server has a clear, predictable style that new tools slot into easily.
- **Test suite momentum**: 29 tests now cover 4 MCP tools (get_feedback_summary, run_test_suite, create_worktree, remove_worktree). Each issue adds to the safety net.
- **Sequential phase dependency handled well**: Phase 2 (orchestrator protocol) references MCP tools from Phase 1. Running them sequentially ensured the tool signatures were finalized before the protocol referenced them.
- **Settings.json change was minimal and safe**: Adding a single top-level key preserved all existing hooks config.

---

## What Caused Friction

- **Worktree merge conflicts not deeply specified**: The orchestrator protocol says "present conflicts to the human" but doesn't describe how to detect or display them. In practice, `git merge` will exit non-zero and print conflict markers — the orchestrator needs to parse that output. This is adequate for now but may need refinement when worktrees are first exercised in real parallel execution.
- **symlinkDirectories is aspirational**: The `.claude/settings.json` worktree config lists directories to symlink, but nothing in the MCP tools actually creates those symlinks. The `create_worktree` tool runs `git worktree add` which doesn't symlink anything — a post-creation hook or additional logic would be needed.

---

## What Should Change in the Agent System

| File | Change | Addresses friction point |
|------|--------|--------------------------|
| `scripts/mcp/project_tools.py` | Add symlink creation logic to `create_worktree` — after `git worktree add`, symlink directories listed in settings.json's `worktree.symlinkDirectories` from the main repo into the worktree | symlinkDirectories not implemented |
| `docs/agents/orchestrator-agent.md` | Add explicit merge conflict detection in 2D: check `git merge` exit code, if non-zero read `git diff --name-only --diff-filter=U` to list conflicted files | Merge conflict handling underspecified |

---

## Suggested Issues

- [ ] Worktree symlink implementation — `create_worktree` should actually create the symlinks listed in `settings.json` worktree.symlinkDirectories
- [ ] Merge conflict resolution protocol — Document explicit steps for the orchestrator when worktree merges conflict
